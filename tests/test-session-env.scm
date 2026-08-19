;;; M2 桌面会话官方化测试（OFF1-OFF12，docs/architecture/
;;; upstream-boundaries.md）。
;;;
;;; 覆盖（composition invariants——capability owner 回归 pinned
;;; Guix 官方 Home services）：
;;;   OFF1 Home 含官方 D-Bus service
;;;   OFF2 Home 含官方 Niri service
;;;   OFF3 Home 含官方 PipeWire service
;;;   OFF4 无 private dbus-run-session owner（custom wrapper 已删）
;;;   OFF5 无 custom HOME setter
;;;   OFF6 无 custom graphical PATH constructor
;;;   OFF7 niri config 保持 declarative（官方 XDG mechanism）
;;;   OFF8 xwayland-satellite 单 provider（Home Niri profile；Home
;;;        packages 不再手工重复）
;;;   OFF9 PipeWire/WirePlumber 单 owner（Home service；niri config
;;;        不再 spawn）
;;;   OFF10 greetd 仍 gated by interactive-session-ready（test-desktop
;;;         D2 覆盖，此处引用）
;;;   OFF11 fallback tty 独立于 desktop（test-desktop D3 覆盖）
;;;   OFF12 Home 仍绑定 system generation（guix-home-service-type）
;;;
;;; 不启动 niri / 不访问公网；仅 evaluate + 源码结构断言。

(use-modules (guixcfg hosts vm)
             (guixcfg home user)
             (guixcfg apps model)       ; applications-home-packages（旧 (guixcfg home packages) 已删）
             (gnu home)
             (gnu home services)
             (gnu home services desktop) ; home-dbus-service-type
             (gnu home services niri)    ; home-niri-service-type
             (gnu home services sound)   ; home-pipewire-service-type
             (gnu services)
             (gnu services guix)         ; guix-home-service-type
             (gnu system)                ; operating-system-services
             (guix packages)             ; package-name
             (gnu packages xorg)         ; xwayland-satellite
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (home-service? svc-type)
  "HOME 的 %guix-home 是否含 SVC-TYPE 服务。"
  (any (lambda (svc) (eq? (service-kind svc) svc-type))
       (home-environment-services %guix-home)))

(test-begin "session-env")

;; ── OFF1/2/3：官方 Home services 存在 ─────────────────────
(test-assert "OFF1: Home contains official D-Bus service"
             (home-service? home-dbus-service-type))

(test-assert "OFF2: Home contains official Niri service"
             (home-service? home-niri-service-type))

(test-assert "OFF3: Home contains official PipeWire service"
             (home-service? home-pipewire-service-type))

;; ── OFF4/5/6：custom wrapper 已删除 ────────────────────────
(test-assert "OFF4: no private dbus-run-session owner in desktop.scm"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "dbus-run-session"))))

(test-assert "OFF5: no custom HOME setter for the session"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "setenv \"HOME\""))))

(test-assert "OFF6: no custom graphical PATH constructor"
             (let ((s (call-with-input-file "modules/guixcfg/system/desktop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "setenv \"PATH\""))))

;; ── OFF7：niri config 声明式（XDG 官方 mechanism）──────────
(test-assert "OFF7: niri config is declarative via XDG mechanism"
             ;; niri 经 native extension（simple-service 'niri-xdg-config
             ;; → home-xdg-configuration-files）贡献 config.kdl。
             (any (lambda (svc)
                    (and (any (lambda (ext)
                                (eq? (service-extension-target ext)
                                     home-xdg-configuration-files-service-type))
                              (service-type-extensions (service-kind svc)))
                         (assoc "niri/config.kdl" (service-value svc))))
                  (home-environment-services %guix-home)))

;; ── OFF8：xwayland-satellite 单 provider ───────────────────
(test-assert "OFF8: xwayland-satellite not duplicated in Home packages"
             (not (memq xwayland-satellite
                        (home-environment-packages %guix-home))))

;; ── OFF9：PipeWire 单 owner（niri config 不再 spawn）───────
(test-assert "OFF9: niri config does not spawn pipewire/wireplumber"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/niri/config.kdl"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "spawn-at-startup \"pipewire\""))
                    (not (string-contains s
                                          "spawn-at-startup \"wireplumber\"")))))

;; ── OFF12：Home 绑定 system generation ─────────────────────
(test-assert "OFF12: Home remains bound to system generation (guix-home-service-type)"
             (any (lambda (svc)
                    (eq? (service-kind svc) guix-home-service-type))
                  (operating-system-services %os)))

;; OFF10/OFF11（greetd gating / fallback tty）由 test-desktop
;; D2/D3 覆盖——composition invariant 见该文件。

(test-end "session-env")
