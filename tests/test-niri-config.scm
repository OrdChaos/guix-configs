;;; niri 配置拆分测试（任务架构调整落地）：config.kdl 薄入口、
;;; common.kdl application-owned 通用配置、host.kdl 由 niri 的
;;; 'laptop configuration variant 解析安装（host 只做 logical
;;; selection）、VM 无 selection 语义、noctalia.kdl ownership 唯一、
;;; 主机/FHS 硬编码审计，以及（store 中存在 pinned niri 二进制时）
;;; niri validate 对最终配置树的真实解析验证。

(use-modules (guix store)         ; open-connection
             (guix monads)
             (guix derivations)
             (guix gexp)              ; plain-file
             (guix build utils)       ; find-files
             (gnu home)              ; home-environment
             (gnu home services)     ; home-xdg-configuration-files-service-type
             (gnu services)          ; service-kind、service-value
             (guixcfg apps model)
             (guixcfg apps niri definition)
             (guixcfg apps selection)
             (guixcfg home user)
             (guixcfg hosts laptop)
             (ice-9 rdelim)          ; read-string
             (ice-9 ftw)             ; scandir
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "niri-config")

;; ── 读取 helper ─────────────────────────────────────────────
(define (read-file p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define %config-kdl (read-file "modules/guixcfg/apps/niri/config.kdl"))
(define %common-kdl (read-file "modules/guixcfg/apps/niri/common.kdl"))
;; laptop-specific KDL 由 niri application colocate（variants/）。
(define %host-kdl
  (read-file "modules/guixcfg/apps/niri/variants/laptop.kdl"))

(define (text-contains-any? text words)
  (any (lambda (w) (string-contains text w)) words))

;; ── 1. config.kdl 是薄入口：include 三件套、无行为内容 ───────
(test-assert "config.kdl includes common.kdl"
             (string-contains %config-kdl "include \"common.kdl\""))
(test-assert "config.kdl includes host.kdl as optional"
             (string-contains %config-kdl
                              "include \"host.kdl\" optional=true"))
(test-assert "config.kdl includes noctalia.kdl as optional"
             (string-contains %config-kdl
                              "include \"noctalia.kdl\" optional=true"))
(test-assert "config.kdl contains no behavior nodes (thin entrypoint)"
             ;; 检查顶层节点形态（注释中的说明文字不算）。
             (not (text-contains-any? %config-kdl
                                      '("binds {" "spawn-at-startup"
                                                  "layout {" "input {" "output {"
                                                  "debug {"))))

;; ── 2. common.kdl：无机器事实残留 ───────────────────────────
(test-assert "common.kdl has no DRM device references"
             (not (text-contains-any? %common-kdl
                                      '("render-drm-device"
                                        "ignore-drm-device"
                                        "/dev/dri"))))
(test-assert "common.kdl has no fixed output name"
             (not (text-contains-any? %common-kdl
                                      '("eDP-1" "Virtual-1" "DP-1"
                                                "HDMI-A-1"))))
(test-assert "common.kdl has no host identifier"
             (not (string-contains %common-kdl "laptop")))

;; ── 3. host.kdl（laptop 源文件）：机器事实、无通用行为 ───────
(test-assert "host.kdl forces the Intel render node"
             (string-contains %host-kdl
                              "render-drm-device \"/dev/dri/by-path/pci-0000:00:02.0-render\""))
(test-assert "host.kdl ignores the NVIDIA dGPU"
             (string-contains %host-kdl
                              "ignore-drm-device \"/dev/dri/by-path/pci-0000:01:00.0-card\""))
(test-assert "host.kdl pins the internal display output"
             (and (string-contains %host-kdl "output \"eDP-1\"")
                  (string-contains %host-kdl "mode \"2560x1600@165.040\"")
                  (string-contains %host-kdl "scale 1.4")))
(test-assert "host.kdl has no application-generic behavior"
             ;; 检查顶层节点形态（注释里的单词不算）。
             (not (text-contains-any? %host-kdl
                                      '("binds {" "input {" "layout {"
                                                  "animations {" "spawn-at-startup"))))

;; ── 4. 主机/FHS 硬编码审计（任务测试 13）────────────────────
(define %all-niri-kdl
  (map read-file
       (find-files "modules/guixcfg/apps/niri" "\\.kdl$")))

(test-assert "no /home/ literal in any niri config or host kdl"
             (not (any (lambda (s) (string-contains s "/home/"))
                       (append %all-niri-kdl (list %host-kdl)))))
(test-assert "no /usr/lib literal in any niri config or host kdl"
             (not (any (lambda (s) (string-contains s "/usr/lib"))
                       (append %all-niri-kdl (list %host-kdl)))))
(test-assert "no developer username in any niri config or host kdl"
             (not (any (lambda (s) (string-contains s "ordchaos"))
                       (append %all-niri-kdl (list %host-kdl)))))

;; ── 5. common.kdl 无 gnome-keyring（GK5 语义延伸）───────────
(test-assert "common.kdl has no gnome-keyring spawn"
             ;; GK5 语义：keyring daemon 的 owner 是 Home Shepherd
             ;; 服务，niri 不得 spawn（头注释中"已移除"记录不算）。
             (not (string-contains %common-kdl
                                   "spawn-at-startup \"gnome-keyring")))

;; ── 6. noctalia.kdl ownership：entrypoint 只 include，不安装 ─
(test-assert "config.kdl includes noctalia.kdl (entrypoint contract)"
             (string-contains %config-kdl "include \"noctalia.kdl\""))
(test-assert "niri application installs no noctalia.kdl"
             (let ((value (service-value
                           (find (lambda (s)
                                   (eq? 'niri-xdg-config
                                        (service-type-name (service-kind s))))
                                 (application-home-services %niri)))))
               (not (assoc "niri/noctalia.kdl" value))))

;; ── 7. niri application 贡献：config.kdl + common.kdl ───────
(define %niri-xdg-value
  (service-value
   (find (lambda (s)
           (eq? 'niri-xdg-config
                (service-type-name (service-kind s))))
         (application-home-services %niri))))

(test-assert "niri application installs config.kdl"
             (assoc "niri/config.kdl" %niri-xdg-value))
(test-assert "niri application installs common.kdl"
             (assoc "niri/common.kdl" %niri-xdg-value))
(test-assert "niri application installs no host.kdl (variant-resolved)"
             (not (assoc "niri/host.kdl" %niri-xdg-value)))

;; ── 8. host 层组合：laptop 只做 logical selection，generic
;;     resolver 把 niri 'laptop variant 解析进 home ───────────
(test-assert "laptop selects the niri laptop variant (logical only)"
             (equal? '((niri laptop))
                     (map (lambda (s)
                            (list (application-configuration-selection-application s)
                                  (application-configuration-selection-variant s)))
                          %laptop-application-configuration-selections)))
(test-assert "laptop home includes the application-configuration-files extension"
             (any (lambda (s)
                    (eq? 'application-configuration-files
                         (service-type-name (service-kind s))))
                  (home-environment-services %laptop-guix-home)))
(test-assert "default home (VM) has no application-configuration-files extension"
             (not (any (lambda (s)
                         (eq? 'application-configuration-files
                              (service-type-name (service-kind s))))
                       (home-environment-services %guix-home))))

;; ── 9. lower 验证：laptop 与 VM 的最终配置目录 ──────────────
(define (lower-xdg-home selection-services)
  "lower 含 niri-xdg-config + SELECTION-SERVICES（resolver 输出）的
合成 home（无包，只装配置文件），返回输出目录。"
  (let* ((store (open-connection))
         (home (home-environment
                (packages '())
                (services (append selection-services
                                  (list (find (lambda (s)
                                                (eq? 'niri-xdg-config
                                                     (service-type-name
                                                      (service-kind s))))
                                              (application-home-services
                                               %niri)))))))
         (drv (run-with-store store (lower-object home))))
    (build-derivations store (list drv))
    (derivation->output-path drv)))

(define %laptop-config-dir
  (string-append
   (lower-xdg-home
    (application-configuration-selections->home-services
     %laptop-application-configuration-selections))
   "/files/.config/niri"))

(define %vm-config-dir
  (string-append
   (lower-xdg-home '())
   "/files/.config/niri"))

(test-assert "laptop config dir contains config.kdl + common.kdl + host.kdl"
             (and (file-exists? (string-append %laptop-config-dir "/config.kdl"))
                  (file-exists? (string-append %laptop-config-dir "/common.kdl"))
                  (file-exists? (string-append %laptop-config-dir "/host.kdl"))))

(test-assert "VM config dir contains config.kdl + common.kdl, no host.kdl"
             (and (file-exists? (string-append %vm-config-dir "/config.kdl"))
                  (file-exists? (string-append %vm-config-dir "/common.kdl"))
                  (not (file-exists? (string-append %vm-config-dir "/host.kdl")))))

(test-assert "neither config dir installs noctalia.kdl (runtime-owned)"
             (and (not (file-exists? (string-append %laptop-config-dir
                                                    "/noctalia.kdl")))
                  (not (file-exists? (string-append %vm-config-dir
                                                    "/noctalia.kdl")))))

(test-assert "installed host.kdl content matches the repo source byte-for-byte"
             (equal? %host-kdl
                     (read-file (string-append %laptop-config-dir
                                               "/host.kdl"))))

;; ── 10. niri validate：真实解析最终配置树（store 有二进制时）─
(define (find-niri-binary)
  "store 中 pinned niri-26.04 的可执行路径；不存在时返回 #f
（测试跳过 validate 组，不依赖公网/构建）。"
  (let ((candidates
         (or (false-if-exception
              (scandir "/gnu/store"
                       (lambda (d)
                         (string-contains d "-niri-26.04"))))
             '())))
    (find (lambda (d)
            (file-exists? (string-append "/gnu/store/" d "/bin/niri")))
          candidates)))

(define %niri-binary
  (and=> (find-niri-binary)
         (lambda (d) (string-append "/gnu/store/" d "/bin/niri"))))

(define (command-success? cmd)
  "system 的退出状态解码（兼容 wait status 与直接退出码两种形态）。"
  (let ((st (system cmd)))
    (cond ((eq? st #f) #f)
      ((not (number? st)) #f)
      ((zero? st) #t)
      (else (let ((v (false-if-exception (status:exit-val st))))
              (and v (zero? v)))))))

(if %niri-binary
  (begin
   (test-assert "niri validate: laptop config tree parses"
                (command-success?
                 (string-append %niri-binary " validate -c "
                                %laptop-config-dir "/config.kdl")))
   (test-assert "niri validate: VM config tree parses (no host.kdl)"
                (command-success?
                 (string-append %niri-binary " validate -c "
                                %vm-config-dir "/config.kdl"))))
  (test-skip "pinned niri binary not in store; validate skipped"))

(test-end "niri-config")
