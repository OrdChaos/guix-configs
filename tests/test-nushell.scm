;;; Nushell application 结构测试：virelith package 来源、声明式 XDG
;;; 配置（config.nu / env.nu / theme.nu / plugin.msgpackz）、构建期生成
;;; 的 plugin registry、persistence 边界（仅 state/history，无
;;; registry 持久化）。
;;;
;;; 覆盖：
;;;   N1  %nushell 安装 virelith 的 nushell@0.115.1（非官方旧版）
;;;   N2  XDG config 恰好包含 config.nu / env.nu / theme.nu /
;;;       plugin.msgpackz
;;;   N3  plugin.msgpackz 是 build-generated file-like（computed-file），
;;;       不是仓库静态文件
;;;   N4  persistence 只有 state rule（.local/state/nushell）；无
;;;       plugin registry persistence rule
;;;   N5  默认注册集合 = 五个官方 default non-developer 插件
;;;   N6  developer/example 插件不声明注册
;;;   N7  registry generator 的 gexp 无 store hash 字面量（hash 由
;;;       file-append 引用自然产生）

(use-modules (guixcfg apps nushell definition)
             (guixcfg apps model)       ; application-home-packages 等
             (guix gexp)                ; computed-file?
             (guix records)
             (gnu home services)        ; home-files-service-type
             (gnu services)             ; service-kind、service-value
             (guix packages)             ; package-name、package-location
             (guix diagnostics)          ; location->string（location-file 未导出）
             (guixcfg system application-persistence) ; rule accessors
             (srfi srfi-1)
             (ice-9 rdelim)             ; read-string
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "nushell")

;; ── N1：package 来源 ────────────────────────────────────────
(test-assert "N1: home-packages is exactly the virelith nushell"
             (let ((pkgs (application-home-packages %nushell)))
               (and (= 1 (length pkgs))
                    (let* ((p (car pkgs))
                           (loc (package-location p)))
                      (and (string=? "nushell" (package-name p))
                           (string=? "0.115.1" (package-version p))
                           (string-contains (location->string loc)
                                            "virelith"))))))

;; ── N2：XDG config 集合 ─────────────────────────────────────
;; simple-service 的 kind 是包装 type（extension 指向 home-files
;; type）——按 test-home.scm 模式经 service-extension-target 识别。
(define %nushell-config-service
  (find (lambda (s)
          (any (lambda (ext)
                 (eq? (service-extension-target ext)
                      home-files-service-type))
               (service-type-extensions (service-kind s))))
        (application-home-services %nushell)))

(define %nushell-config-files
  (map car (service-value %nushell-config-service)))

(test-assert "N2: xdg config contains config.nu/env.nu/theme.nu/plugin.msgpackz"
             (and (member ".config/nushell/config.nu" %nushell-config-files)
                  (member ".config/nushell/env.nu" %nushell-config-files)
                  (member ".config/nushell/theme.nu" %nushell-config-files)
                  (member ".config/nushell/plugin.msgpackz" %nushell-config-files)))

(test-equal "N2: xdg config is exactly the four declarative files"
            4 (length %nushell-config-files))

;; ── N3：plugin.msgpackz 是构建期生成物 ─────────────────────
;; home-files service value 条目是 (target file-like) 两元素列表。
(define %nushell-config-sources
  (map cadr (service-value %nushell-config-service)))

(test-assert "N3: plugin.msgpackz source is a computed-file"
             (any (lambda (src)
                    (and (computed-file? src)
                         (string-contains (computed-file-name src)
                                          "plugin-registry")))
                  %nushell-config-sources))

(test-assert "N3: config.nu/env.nu are local-file (static), not generated"
             (every (lambda (src)
                      (or (local-file? src)
                          (and (computed-file? src)
                               (string-contains (computed-file-name src)
                                                "plugin-registry"))))
                    %nushell-config-sources))

;; ── N4：persistence 边界 ────────────────────────────────────
(test-assert "N4: persistence is exactly the state/history rule"
             (let ((rules (application-persistence %nushell)))
               (and (= 1 (length rules))
                    (let ((r (car rules)))
                      (and (string=? ".local/state/nushell"
                                     (application-persistence-rule-consumer r))
                           (eq? 'bind-directory
                                (application-persistence-rule-exposure r)))))))

(test-assert "N4: no persistence rule covers the plugin registry"
             (every (lambda (r)
                      (not (string-contains
                            (application-persistence-rule-consumer r)
                            "plugin")))
                    (application-persistence %nushell)))

;; ── N5/N6：插件声明集合 ─────────────────────────────────────
(test-equal "N5: default registry is exactly the five official plugins"
            '("nu_plugin_inc" "nu_plugin_polars" "nu_plugin_gstat"
                              "nu_plugin_formats" "nu_plugin_query")
            %nushell-default-plugins)

(test-assert "N6: developer/example plugins are not declared"
             (every (lambda (p)
                      (not (member p %nushell-default-plugins)))
                    '("nu_plugin_custom_values" "nu_plugin_example"
                                                "nu_plugin_stress_internals")))

;; ── N7：generator 无 store hash 字面量 ──────────────────────
(test-assert "N7: definition contains no /gnu/store hash literal"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/nushell/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s "/gnu/store/"))))

;; ── N8：GPG_TTY 转发（2026-09 根因修复）────────────────────
;; git 签名以 pipe_command 喂数据给 gpg（gpg fd0=管道，ttyname(0)
;; 回退失效），GPG_TTY 环境变量是 tty 到达 agent 的唯一通道；
;; Wayland-only 会话（无 DISPLAY）时 pinentry 退 curses 在终端画
;; 密码框。nu 是 ghostty 的默认 shell——env.nu 每次启动求值，
;; do -i 容忍无 tty 上下文（不能进静态 home-environment-variables）。
(test-assert "N8: env.nu exports GPG_TTY with a no-tty guard"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/nushell/env.nu"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "$env.GPG_TTY")
                    (string-contains s "do -i")
                    (string-contains s "^tty"))))

(test-end "nushell")
