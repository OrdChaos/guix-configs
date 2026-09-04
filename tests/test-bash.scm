;;; Bash app 测试：shell rc 所有权（home-bash-configuration）与
;;; GPG/pinentry 的 tty 转发（2026-09 根因修复）。
;;;
;;; 覆盖：
;;;   BS1  bash app 经 home-bash-service-type 贡献配置；
;;;   BS2  bashrc 导出 GPG_TTY（per-shell 动态 tty；pinentry 在
;;;        Wayland-only 会话退 curses 时经 OPTION ttyname 使用它，
;;;        缺失时签名失败 "Inappropriate ioctl for device"）；
;;;        环境变量表保持静态（EDITOR/VISUAL/PAGER 不受影响）。
;;;
;;; 注意：home-bash-configuration 的 field accessors 未随模块导出
;;; （pinned guix shells.scm 只导出 record 与 service-type），测试经
;;; (guix records) 的 record-type-descriptor + record-accessor 访问。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (gnu home services shells) ; home-bash-service-type
             (gnu services)             ; service-kind、service-value
             (guix records)             ; record-type-descriptor、record-accessor
             (ice-9 rdelim)             ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "bash")

(define (app-by-name name)
  (find (lambda (a) (eq? name (application-name a))) %applications))

(define %bash-app (app-by-name 'bash))

(define %bash-config
  (service-value
   (find (lambda (s)
           (eq? home-bash-service-type (service-kind s)))
         (application-home-services %bash-app))))

(define (bash-field name)
  "home-bash-configuration 的 field accessor（经 record type descriptor）。"
  (record-accessor (record-type-descriptor %bash-config) name))

;; ── BS1：app 启用 + home-bash 配置 ─────────────────────────
(test-assert "BS1: bash app enabled and contributes home-bash-configuration"
             (and %bash-app
                  (application? %bash-app)
                  %bash-config))

;; ── BS2：GPG_TTY 转发（bashrc，非静态环境变量表）───────────
(test-assert "BS2: bashrc ships the colocated gpg-tty.bashrc (local-file)"
             (let ((rcs ((bash-field 'bashrc) %bash-config)))
               (and (pair? rcs)
                    (any (lambda (f)
                           (string-contains (object->string f)
                                            "gpg-tty"))
                         rcs))))

(test-assert "BS2: gpg-tty.bashrc exports GPG_TTY for pinentry tty forwarding"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/bash/gpg-tty.bashrc"
                       (lambda (p) (read-string p)))))
               (string-contains s "GPG_TTY")))

(test-assert "BS2: GPG_TTY stays dynamic (bashrc), not a static env var"
             (let ((vars ((bash-field 'environment-variables) %bash-config)))
               (not (any (lambda (pair)
                           (string=? "GPG_TTY" (car pair)))
                         vars))))

(test-end "bash")
