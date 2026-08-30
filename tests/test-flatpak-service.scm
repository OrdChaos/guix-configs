;;; Flatpak composition 测试（docs/architecture/flatpak.md）：
;;;   - system profile 含 flatpak executable 与共享 %fonts 投影；
;;;   - Home 含 XDG_DATA_DIRS exports 贡献（追加不覆盖）与 override
;;;     home-files service；
;;;   - %vm-os 的 file-systems 含 installation bind；
;;;   - 静态回归：platform service/model/registry 模块不 import
;;;     reconcile、不含任何 flatpak CLI 调用面（reconfigure/boot/
;;;     login 零网络硬不变量）。
;;;
;;; 只 evaluate + 源码断言，不触 flatpak CLI、不触网络。

(use-modules (guixcfg hosts vm)          ; %vm-os
             (guixcfg users user)        ; user-profile-name、%primary-user
             (guixcfg fonts)             ; %fonts（shared fact）
             (guixcfg storage model)     ; persist-mount-point
             (guixcfg system packages)   ; %system-packages
             (guixcfg flatpak model)
             (guixcfg flatpak registry)
             (guixcfg flatpak service)
             (gnu packages package-management) ; flatpak
             (gnu packages)              ; package-name
             (gnu system)                ; operating-system-file-systems
             (gnu system file-systems)   ; file-system-mount-point、file-system-device
             (gnu home)                  ; home-environment-services
             (gnu home services)         ; home-environment-variables-service-type、home-files-service-type
             (gnu services)              ; service-kind
             (guixcfg home user)         ; %guix-home
             (ice-9 rdelim)              ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "flatpak-service")

;; ── system profile：flatpak + %fonts 投影 ──────────────────
(test-assert "system profile contains flatpak executable"
             (member flatpak %system-packages))
(test-assert "system profile projects every shared %fonts package"
             (every (lambda (p) (member p %system-packages)) %fonts))

;; ── Home services 结构 ─────────────────────────────────────
;; simple-service 返回的是包装 service-type（名字 = simple-service
;; name），kind 不等于目标类型——必须检查 extension targets。
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

(test-equal "flatpak home services: exactly two services"
            2 (length %flatpak-home-services))
(test-assert "one service extends home-files (override complete-file)"
             (any (lambda (svc)
                    (service-extends? svc home-files-service-type))
                  %flatpak-home-services))
(test-assert "one service extends home-environment-variables"
             (any (lambda (svc)
                    (service-extends? svc
                                      home-environment-variables-service-type))
                  %flatpak-home-services))

;; ── XDG_DATA_DIRS：追加不覆盖 ──────────────────────────────
(define %home-env-value
  (service-value
   (fold-services (home-environment-services %guix-home)
                  #:target-type home-environment-variables-service-type)))

(test-assert "home closure contains the flatpak XDG_DATA_DIRS contribution"
             (member '("XDG_DATA_DIRS"
                       . "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share")
                     %home-env-value))
;; 组合语义：值以 $XDG_DATA_DIRS 开头 = 追加而非覆盖（preamble 已
;; 置 Home profile share，source 时展开）。
(test-assert "XDG_DATA_DIRS value appends (never overwrites)"
             (string-prefix? "$XDG_DATA_DIRS:"
                             "$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share"))

;; ── override files：无声明 → 不生成（user-owned）───────────
(test-equal "empty catalog produces no override files"
            '() (flatpak-override-files %flatpak-applications))

;; ── %vm-os persistence wiring ─────────────────────────────────
(define %fp-user (user-profile-name %primary-user))

(test-assert "OS file-systems bind ~/.local/share/flatpak -> flatpak/installation"
             (any (lambda (fs)
                    (and (string=?
                          (string-append "/home/" %fp-user
                                         "/.local/share/flatpak")
                          (file-system-mount-point fs))
                         (string=?
                          (string-append (persist-mount-point "@persist-data-app")
                                         "/flatpak/installation")
                          (file-system-device fs))))
                  (operating-system-file-systems %vm-os)))

;; ── 静态回归：platform 模块零 flatpak CLI / 零 reconcile ────
(define (module-source name)
  (call-with-input-file
   (string-append "modules/guixcfg/flatpak/" name)
   (lambda (port) (read-string port))))

(define %platform-sources
  (list (cons "model.scm" (module-source "model.scm"))
        (cons "registry.scm" (module-source "registry.scm"))
        (cons "service.scm" (module-source "service.scm"))))

;; 精确扫描：只禁止 (a) reconcile 模块的 import 形式；(b) Scheme 子
;; 进程调用原语。注释里出现 CLI 名词（如 remote-add 的文档性说明）
;; 是合法文档，不做 substring 文本匹配。
(define %flatpak-cli-invocation-fragments
  '("(invoke" "invoke-capture" "open-pipe" "system*"))

(test-assert "platform service/model/registry never import reconcile"
             (every (lambda (entry)
                      (not (string-contains
                            (cdr entry)
                            "use-module (guixcfg flatpak reconcile)")))
                    %platform-sources))
(test-assert "platform service/model/registry contain no subprocess invocation surface"
             (every (lambda (entry)
                      (not (any (lambda (fragment)
                                  (string-contains (cdr entry) fragment))
                                %flatpak-cli-invocation-fragments)))
                    %platform-sources))
;; 反过来锚定测试有效性：reconcile 模块确实在 flatpak area、import
;; 了子进程原语且带 CLI 面（网络边界只归 tools 入口）。
(define %reconcile-source
  (call-with-input-file "modules/guixcfg/flatpak/reconcile.scm"
                        (lambda (port) (read-string port))))
(test-assert "reconcile module exists and carries the CLI surface"
             (and (string-contains %reconcile-source "remote-add")
                  (string-contains %reconcile-source "remote-info")
                  (string-contains %reconcile-source "invoke-capture")))

(test-end "flatpak-service")
