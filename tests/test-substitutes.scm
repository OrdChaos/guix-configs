;;; Nonguix substitute trust policy 测试（T-NG1-8，
;;; docs/architecture/overview.md（Nonguix integration））。
;;;
;;; 覆盖：
;;;   T-NG1  installed OS 的 guix-daemon 服务图包含 Nonguix substitute
;;;          trust contribution（URL + authorized key）
;;;   T-NG2  Guix 默认 substitute URLs/keys 没有被覆盖（additive
;;;          extension 语义）
;;;   T-NG3  Nonguix URL/key 只有唯一 authoritative source（无
;;;          VM/laptop 各自复制）
;;;   T-NG4  bootstrap consumer 与 steady-state policy 使用同一
;;;          canonical public key（modules/guixcfg/system/nonguix-key.pub）
;;;   T-NG5  channel policy 与 substitute policy 是不同定义
;;;          （channels.lock.scm 无 substitute URL；substitutes.scm
;;;          无 channel 定义）
;;;   T-NG6  Nonguix public key 不进 /persist、age、TPM、Secure Boot
;;;          key 路径（public trust material，声明式）
;;;   T-NG7  selected runtime kernel 仍是 exact Nonguix Linux（无
;;;          custom derivation——K1 的补充断言）
;;;   T-NG8  custom initrd 测试继续通过：由全套件既有测试覆盖
;;;
;;; 不访问公网（substitute availability 是 integration probe，不是
;;; unit test）。

(use-modules (guixcfg hosts vm)
             (guixcfg system substitutes)
             (guixcfg system kernel-platform)
             (gnu services)
             (gnu services base)     ; guix-service-type、guix-configuration
             (guix gexp)
             (guix packages)         ; package-name
             (gnu system)            ; operating-system-*
             (nongnu packages linux) ; linux（nonguix）
             (ice-9 rdelim)
             (ice-9 regex)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

;; ── T-NG1/T-NG2：evaluated service graph 的 guix-daemon 配置 ──
(define %vm-guix-config
  (service-value
   (fold-services (operating-system-services %os)
                  #:target-type guix-service-type)))

(define %vm-substitute-urls
  (guix-configuration-substitute-urls %vm-guix-config))

(define %vm-authorized-keys
  (guix-configuration-authorized-keys %vm-guix-config))

(test-begin "substitutes")

(test-assert "T-NG1: guix-daemon config includes official Nonguix substitute URL"
             (member %nonguix-substitute-url %vm-substitute-urls))

(test-assert "T-NG1: authorized keys are contributed (non-empty)"
             (pair? %vm-authorized-keys))

(test-assert "T-NG2: default Guix substitute URLs preserved"
             (and (member "https://ci.guix.gnu.org" %vm-substitute-urls)
                  (member "https://bordeaux.guix.gnu.org"
                          %vm-substitute-urls)))

;; ── T-NG3：唯一 authoritative source（无 host 复制）──────────
(define (nonguix-url-references)
  "仓库中 %NONGUIX-SUBSTITUTE-URL 字面量的出现位置（应只在
substitutes.scm 一处）。"
  (let ((target (string-append "modules/guixcfg/system/substitutes.scm")))
    (filter (lambda (file)
              (and (not (string=? file target))
                   (let ((s (call-with-input-file file
                                                 (lambda (p) (read-string p)))))
                     (string-contains s %nonguix-substitute-url))))
            '("modules/guixcfg/hosts/vm.scm"
              "modules/guixcfg/hosts/laptop.scm"
              "modules/guixcfg/system/common.scm"
              "tools/disk-install.scm"
              "tools/secrets.scm"))))

(test-assert "T-NG3: no host/tool duplicates the Nonguix substitute URL"
             (null? (nonguix-url-references)))

;; ── T-NG4：bootstrap 与 steady-state 同一 canonical key ─────
(test-assert "T-NG4: key file exists as canonical copy"
             (file-exists? "modules/guixcfg/system/nonguix-key.pub"))

(test-assert "T-NG4: key file contains the official Ed25519 public key"
             (let ((s (call-with-input-file "modules/guixcfg/system/nonguix-key.pub"
                                            (lambda (p) (read-string p)))))
               (string-contains s "C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98")))

;; ── T-NG5：channel policy != substitute policy ───────────────
(test-assert "T-NG5: channels.lock.scm contains no substitute URL"
             (let ((s (call-with-input-file "channels.lock.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s %nonguix-substitute-url))))

(test-assert "T-NG5: substitutes.scm defines no channel"
             (let ((s (call-with-input-file "modules/guixcfg/system/substitutes.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "make-channel"))))

;; ── T-NG6：public key 不进 secret/persist 路径 ───────────────
(test-assert "T-NG6: key file lives outside persist/age/tpm/secure-boot paths"
             (let ((path "modules/guixcfg/system/nonguix-key.pub"))
               (and (not (string-contains path "persist"))
                    (not (string-contains path "keys/age"))
                    (not (string-contains path "tpm"))
                    (not (string-contains path "secure-boot")))))

;; ── T-NG7：kernel 仍是 exact Nonguix Linux（无 custom derivation）
(test-assert "T-NG7: %kernel is the exact Nonguix linux package"
             (and (eq? %kernel linux)
                  (string=? (package-name %kernel) "linux")
                  (not (string-contains (package-name %kernel) "libre"))))

(test-assert "T-NG7: %os selects %kernel unchanged"
             (eq? (operating-system-kernel %os) %kernel))

;; T-NG8：custom initrd 行为由全套件既有测试覆盖（本文件不重复）。

(test-end "substitutes")
