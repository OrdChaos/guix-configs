;;; 第三方 substitute 移除回归测试（2026-08-25 决策）：仓库不引入任何
;;; 第三方 substitute 服务（substitutes.nonguix.org）——guix-daemon
;;; 只信任官方 Guix substitute（bordeaux/ci.guix.gnu.org，guix-service-
;;; type 默认值）；nonguix 包（linux-7.2/firmware/microcode）一律本地
;;; 编译（docs/architecture/overview.md（Nonguix integration））。
;;;
;;; 覆盖：
;;;   T-S1  installed OS 的 guix-daemon substitute-urls 不含 Nonguix
;;;          URL（官方默认 bordeaux/ci 保留）
;;;   T-S2  modules/ 无第三方 substitute URL 字面量（原 substitutes.scm
;;;          已删除；断言仓库不再出现，杜绝复活）
;;;   T-S3  无 (guixcfg system substitutes) 模块 import（模块已删除）
;;;   T-S4  nonguix-key.pub 已删除（无第三方信任材料残留）
;;;   T-S5  channels.lock.scm 无 substitute URL（channel policy !=
;;;          substitute policy）
;;;   T-S6  %kernel 仍是 exact Nonguix linux-7.2（无 custom derivation）
;;;
;;; 不访问公网（substitute availability 是 integration probe，不是
;;; unit test）。

(use-modules (guixcfg hosts vm)
             (guixcfg system kernel-platform)
             (gnu services)
             (gnu services base)     ; guix-service-type、guix-configuration
             (guix packages)         ; package-name
             (gnu system)            ; operating-system-*
             (nongnu packages linux) ; linux-7.2（nonguix）
             (guix build utils)      ; find-files
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; 第三方 substitute 的 canonical URL 字面量（移除对象的指纹；
;; 仓库中任何出现都视为复活）。
(define %nonguix-substitute-url "https://substitutes.nonguix.org")

;; ── T-S1：evaluated service graph 的 guix-daemon 配置 ───────
(define %vm-guix-config
  (service-value
   (fold-services (operating-system-services %os)
                  #:target-type guix-service-type)))

(define %vm-substitute-urls
  (guix-configuration-substitute-urls %vm-guix-config))

(test-begin "substitutes")

(test-assert "T-S1: guix-daemon config contains NO third-party substitute URL"
             (not (member %nonguix-substitute-url %vm-substitute-urls)))

(test-assert "T-S1: official Guix substitute URLs preserved (default)"
             (and (member "https://ci.guix.gnu.org" %vm-substitute-urls)
                  (member "https://bordeaux.guix.gnu.org"
                          %vm-substitute-urls)))

;; ── T-S2/T-S3/T-S4：仓库无第三方 substitute 残留 ────────────
(define %scm-files
  (find-files "modules" "\\.scm$"))

(test-assert "T-S2: no module contains the third-party substitute URL"
             (every (lambda (file)
                      (let ((s (call-with-input-file file
                                                     (lambda (p) (read-string p)))))
                        (not (string-contains s %nonguix-substitute-url))))
                    %scm-files))

(test-assert "T-S3: (guixcfg system substitutes) module is gone"
             (not (member "modules/guixcfg/system/substitutes.scm"
                          %scm-files)))

(test-assert "T-S3: no module imports the removed substitutes module"
             (every (lambda (file)
                      (let ((s (call-with-input-file file
                                                     (lambda (p) (read-string p)))))
                        (not (string-contains s
                                              "(guixcfg system substitutes)"))))
                    %scm-files))

(test-assert "T-S4: nonguix-key.pub is gone (no third-party trust material)"
             (not (file-exists? "modules/guixcfg/system/nonguix-key.pub")))

;; ── T-S5：channel policy != substitute policy ────────────────
(test-assert "T-S5: channels.lock.scm contains no substitute URL"
             (let ((s (call-with-input-file "channels.lock.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s %nonguix-substitute-url))))

;; ── T-S6：kernel 仍是 exact Nonguix linux-7.2（无 custom derivation）
(test-assert "T-S6: %kernel is the exact Nonguix linux-7.2 package"
             (and (eq? %kernel linux-7.2)
                  (string=? (package-name %kernel) "linux")
                  (not (string-contains (package-name %kernel) "libre"))))

(test-assert "T-S6: %os selects %kernel unchanged"
             (eq? (operating-system-kernel %os) %kernel))

(test-end "substitutes")
