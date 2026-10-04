;;; Substitute policy 回归测试。
;;;
;;; 当前策略（2026-10-04）：
;;;   - substitute-urls 显式全列，顺序即优先级：SJTU 镜像 →
;;;     cache-cdn.guix.moe → 官方 ci/bordeaux → substitutes.nonguix.org
;;;     （origin 兜底）；
;;;   - SJTU 与 cache-cdn 的主线内容是官方 berlin 签名 narinfo 的镜像，
;;;     免新密钥；
;;;   - nonguix 签名 key 经 system/nonguix-key.pub 授权（与
;;;     https://substitutes.nonguix.org/signing-key.pub 一致），nonguix
;;;     包（linux-7.2/firmware/microcode）可走 substitute——nonguix.org
;;;     与 guix.moe 已于 2026-08-23 合并运营（guix-devel 2026-08-07
;;;     公告），且其内容已有 cache-cdn 镜像承载；
;;;   - 沿革：2026-08-25 曾移除（当时无镜像、可靠性存疑），2026-10-04
;;;     随合并运营 + 镜像体系可用而恢复。
;;;
;;; 覆盖：
;;;   T-S1  substitute-urls 含 nonguix URL（恢复后必须在列）；官方
;;;          ci/bordeaux 保留
;;;   T-S7  SJTU 与 cache-cdn.guix.moe 镜像在列且排在官方之前；
;;;          nonguix URL 排最后（origin 兜底）
;;;   T-S8  nonguix-key.pub 存在且内容含 nonguix key 指纹；已加入
;;;          guix-configuration 的 authorized-keys
;;;   T-S5  channels.lock.scm 无 substitute URL（channel policy !=
;;;          substitute policy）
;;;
;;; 不访问公网（substitute availability 是 integration probe，不是
;;; unit test）。

(use-modules (guixcfg hosts vm)
             (gnu services)
             (gnu services base)     ; guix-service-type、guix-configuration
             (gnu system)            ; operating-system-*
             (guix gexp)             ; local-file?
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %nonguix-substitute-url "https://substitutes.nonguix.org")

;; nonguix 签名 key 的 Ed25519 指纹（nonguix README / signing-key.pub）。
(define %nonguix-key-fingerprint
  "C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98")

;; ── evaluated service graph 的 guix-daemon 配置 ─────────────
(define %vm-guix-config
  (service-value
   (fold-services (operating-system-services %vm-os)
                  #:target-type guix-service-type)))

(define %vm-substitute-urls
  (guix-configuration-substitute-urls %vm-guix-config))

(define (list-index pred lst)
  (let loop ((rest lst) (i 0))
    (cond ((null? rest) #f)
          ((pred (car rest)) i)
          (else (loop (cdr rest) (1+ i))))))

(test-begin "substitutes")

;; ── T-S1：URL 集合 ─────────────────────────────────────────
(test-assert "T-S1: nonguix substitute URL is present (restored 2026-10-04)"
             (member %nonguix-substitute-url %vm-substitute-urls))

(test-assert "T-S1: official Guix substitute URLs preserved"
             (and (member "https://ci.guix.gnu.org" %vm-substitute-urls)
                  (member "https://bordeaux.guix.gnu.org"
                          %vm-substitute-urls)))

;; ── T-S7：镜像优先、origin 兜底 ────────────────────────────
(test-assert "T-S7: mirrors precede official servers; nonguix origin is last"
             (let ((sjtu (list-index
                          (lambda (u) (string=? u "https://mirror.sjtu.edu.cn/guix"))
                          %vm-substitute-urls))
                   (moe (list-index
                         (lambda (u) (string=? u "https://cache-cdn.guix.moe"))
                         %vm-substitute-urls))
                   (ci (list-index
                        (lambda (u) (string=? u "https://ci.guix.gnu.org"))
                        %vm-substitute-urls))
                   (nonguix (list-index
                             (lambda (u) (string=? u %nonguix-substitute-url))
                             %vm-substitute-urls)))
               (and sjtu moe ci nonguix
                    (< sjtu ci)
                    (< moe ci)
                    (< ci nonguix))))

;; ── T-S8：nonguix 信任材料 ─────────────────────────────────
(test-assert "T-S8: nonguix-key.pub exists with the expected fingerprint"
             (let ((key-file "modules/guixcfg/system/nonguix-key.pub"))
               (and (file-exists? key-file)
                    (string-contains
                     (call-with-input-file key-file
                                           (lambda (p) (read-string p)))
                     %nonguix-key-fingerprint))))

(test-assert "T-S8: nonguix-key.pub is in guix-daemon authorized-keys"
             (find (lambda (f)
                     (and (local-file? f)
                          (string=? (local-file-name f) "nonguix-key.pub")))
                   (guix-configuration-authorized-keys %vm-guix-config)))

;; ── T-S5：channel policy != substitute policy ────────────────
(test-assert "T-S5: channels.lock.scm contains no substitute URL"
             (let ((s (call-with-input-file "channels.lock.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s %nonguix-substitute-url))))

(test-end "substitutes")
