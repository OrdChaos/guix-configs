;;; niri application unit：用户桌面生命周期（自定义 home-niri-session
;;; service type——官方 home-niri-service-type 的薄 fork，见下；bash -l
;;; -c wrapper 跑 niri --session；profile 自动贡献 dbus/niri/
;;; xdg-desktop-portal-*/xwayland-satellite；requirement home-dbus）
;;; + niri 公开配置（config.kdl 入口 + common.kdl 通用配置 + 可选
;;; configuration variants，本目录 colocate）。
;;;
;;; ── 注销 lifecycle（2026-08-24 决策记录）────────────────────
;;; 官方 home-niri-service-type 的 shepherd service 未设 respawn?
;;; （<shepherd-service> 默认 #t）——niri 退出会被 Home Shepherd
;;; 立即 respawn，注销退化为"重启合成器"。本模块 fork 官方 service
;;; 只改 lifecycle：
;;;   - respawn? #f：niri 退出 = 桌面会话结束，不重启；
;;;   - start：Guile 原生 wrapper（program-file，AGENT.md §3）——
;;;     fork+exec niri --session，niri 正常退出（含 crash）后
;;;     `loginctl terminate-session $XDG_SESSION_ID` 结束当前登录
;;;     会话，greetd 观察到会话结束 → 回 greeter；
;;;   - stop：先写 guard marker 再杀进程组（make-kill-destructor
;;;     语义不变）。wrapper 检测到 guard 存在 → 只退出、不注销——
;;;     herd stop / guix home reconfigure（herd load → restart）
;;;     不等于注销。
;;; 其余 extension（home-dbus / home-profile 包列表）与官方逐字一致。
;;; XDG_SESSION_ID 传递链（pinned 源码审计）：pam_elogind open_session
;;; setenv（pam_elogind.c:1226）→ greetd worker envvec → bash -l →
;;; Home Shepherd（常驻，继承环境）→ niri 服务 make-forkexec-constructor
;;; 的 #:environment-variables 继承 (environ)（官方 niri 同款模式）
;;; → wrapper 内可用。greetd 官方 wrapper（base.scm:3714
;;; make-greetd-xdg-user-session-command）只设 XDG_SESSION_TYPE/
;;; XDG_RUNTIME_DIR，不覆盖 XDG_SESSION_ID。不得硬编码 session ID。
;;;
;;; 配置树（docs/architecture/graphics.md）：
;;;   config.kdl   薄入口：include common.kdl + host.kdl(optional) +
;;;                noctalia.kdl(optional)（include 语义见文件头注释）
;;;   common.kdl   application-owned：全部机器无关行为
;;;   variants/    application-owned 可选配置变体（如 laptop.kdl）：
;;;                application 声明变体及其文件/目标路径；host 层只
;;;                做 logical selection（(guixcfg apps selection)），
;;;                不知道文件与路径
;;;   host.kdl     由 'laptop variant 解析安装（~/.config/niri/
;;;                host.kdl）；VM 无 selection → 不安装（config.kdl
;;;                的 optional include 仅警告）
;;;   noctalia.kdl 运行时由 Noctalia 生成（唯一 owner = Noctalia；
;;;                本模块不安装、不声明）
;;;
;;; 经官方 home-xdg-configuration-files-service-type 以 source-
;;; relative local-file 声明（pinned Guix local-file 宏按出现处
;;; source directory 解析）——derived state，每次 fresh root/Home
;;; activation 恢复；不持久化、app 不是第二 authority。

(define-module (guixcfg apps niri definition)
               #:use-module (gnu home services)      ; home-shepherd-service-type
               #:use-module (gnu home services desktop) ; home-dbus-service-type
               #:use-module (gnu home services shepherd) ; shepherd-service
               #:use-module (gnu packages freedesktop) ; xdg-desktop-portal*
               #:use-module (gnu packages glib)      ; dbus
               #:use-module (gnu packages gnome)     ; xdg-desktop-portal-gnome
               #:use-module (gnu packages window-management) ; niri
               #:use-module (gnu packages xorg)      ; xwayland-satellite
               #:use-module (gnu services)           ; service、service-type
               #:use-module (guix gexp)              ; local-file、gexp、program-file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%niri
                         %niri-session-wrapper ; 测试（test-runtime-exec NI1 真实执行）
                         home-niri-session-service-type))

;; guard marker 路径：$XDG_RUNTIME_DIR 下（Home Shepherd 必有；fallback
;; 用 /tmp，仅防御）。运行期求值（shepherd 进程内 getenv）——不能
;; 构建期拼接。
(define %niri-logout-guard
  #~(string-append (or (getenv "XDG_RUNTIME_DIR") "/tmp")
                   "/niri-logout-guard"))

;; niri 会话 wrapper（Guile 原生，非 bash 字符串——AGENT.md §3）：
;; fork+exec niri --session（绝对路径，不依赖 PATH），niri 退出后
;; （任何原因）结束当前登录会话。guard marker 区分 shepherd 主动
;; stop（herd stop / home reconfigure 的 restart / shutdown）与 niri
;; 自退：stop 路径先写 marker 再杀进程组（见 service stop），wrapper
;; 看到 marker 只退出不注销。start 时先清理残留 marker（上次 stop
;; 竞态遗留）。terminate-session 失败（session 已被清理等）只记
;; 日志、不阻塞退出——benign。退出码保留 niri 的（信号退出按
;; bash $? 语义 128+signal）。
(define %niri-session-wrapper
  (program-file
   "niri-session"
   #~(begin
       ;; 全部 binding 均为 Guile core（status:exit-val/term-sig 是
       ;; libguile 内建导出，无需 (ice-9 posix)——program-file 的
       ;; load path 不含 guile 模块树，非 core import 会失败）。
       (define guard #$%niri-logout-guard)
       ;; 清理上次 stop 竞态遗留的 guard marker。
       (when (file-exists? guard)
         (delete-file guard))
       (let ((pid (primitive-fork)))
         (if (zero? pid)
             ;; child：exec niri（file-append 绝对路径）。
             (execl #$(file-append niri "/bin/niri") "niri" "--session")
             (let* ((status (cdr (waitpid pid)))
                    (code (if (status:term-sig status)
                              (+ 128 (status:term-sig status))
                              (status:exit-val status))))
               (if (file-exists? guard)
                   ;; shepherd 主动 stop：只退出，不结束登录会话。
                   (delete-file guard)
                   (let ((session-id (getenv "XDG_SESSION_ID")))
                     (if session-id
                         (catch 'system-error
                           (lambda ()
                             (let ((r (system* "loginctl"
                                               "terminate-session"
                                               session-id)))
                               (unless (zero? r)
                                 (format (current-error-port)
                                         "niri session: loginctl terminate-session failed (status ~a)~%"
                                         r))))
                           (lambda args
                             (format (current-error-port)
                                     "niri session: loginctl terminate-session failed: ~a~%"
                                     (caddr args))))
                         (format (current-error-port)
                                 "niri session: XDG_SESSION_ID unset, cannot terminate session~%"))))
               (exit code)))))))

(define (home-niri-session-shepherd-service config)
  "Return a shepherd service that runs Niri; on Niri exit the login
session is terminated (unless the service was stopped by shepherd).
Thin fork of the official 'home-niri-shepherd-service' with the
logout lifecycle: respawn? #f + wrapper that runs
'loginctl terminate-session' after Niri exits."
  (list (shepherd-service
         (documentation
          "Run Niri; terminate the login session when it exits.")
         (provision '(niri))
         (requirement '(dbus))
         (respawn? #f)
         (start #~(make-forkexec-constructor
                   (list #$%niri-session-wrapper)
                   #:environment-variables
                   (append (list "DESKTOP_SESSION=niri"
                                 "XDG_CURRENT_DESKTOP=niri"
                                 "XDG_SESSION_DESKTOP=niri"
                                 "XDG_SESSION_TYPE=wayland")
                           (filter (negate
                                    (lambda (str)
                                      (string-prefix? "WAYLAND_DISPLAY=" str)))
                                   (environ)))))
         ;; 先写 guard marker（wrapper 检测到只退出不注销），再按官方
         ;; make-kill-destructor 语义杀进程组。marker 写入失败（几乎
         ;; 不可能）不阻塞 stop；残留 marker 由 wrapper 下次 start 时
         ;; 清理。
         (stop #~(lambda (pid . args)
                   (let ((guard #$%niri-logout-guard))
                     (false-if-exception
                      (call-with-output-file guard
                                             (lambda (port) #t)))
                     (apply (make-kill-destructor) pid args)))))))

(define home-niri-session-service-type
  (service-type
   (name 'home-niri-session)
   (extensions
    (list (service-extension home-shepherd-service-type
                             home-niri-session-shepherd-service)
          (service-extension home-dbus-service-type
                             (const '()))
          (service-extension home-profile-service-type
                             (lambda (config)
                               (list dbus
                                     niri
                                     xdg-desktop-portal
                                     xdg-desktop-portal-gnome
                                     xdg-desktop-portal-gtk
                                     xwayland-satellite)))))
   (description
    "Run Niri as the Wayland desktop session; terminating the login
session when Niri exits so that greetd returns to the greeter.")
   (default-value #t)))

(define %niri
  (application
   (name 'niri)
   (home-services
    (list (service home-niri-session-service-type)
          ;; 共享 sink（home-xdg-configuration-files）经 Guix native
          ;; extension 贡献（simple-service → target；canonical target
          ;; 由 instantiate-missing-services 以 default '() 自动实例化
          ;; ——见 AGENT.md §15 / docs/architecture/applications.md）。
          (simple-service 'niri-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("niri/config.kdl"
                             ,(local-file "config.kdl" "niri-config.kdl"))
                            ("niri/common.kdl"
                             ,(local-file "common.kdl" "niri-common.kdl"))))))
   ;; 可选配置变体（application-owned）：'laptop 携带机器事实
   ;; （DRM 选择、固定内屏输出），解析安装为 ~/.config/niri/host.kdl
   ;; ——target 是完整 ~/.config 相对路径，与 application name 无
   ;; 耦合；host 层只按 (niri, laptop) 选择。
   (configuration-variants
    (list (application-configuration-variant
           (name 'laptop)
           (files `(("niri/host.kdl"
                     ,(local-file "variants/laptop.kdl"
                                  "niri-laptop.kdl")))))))))
