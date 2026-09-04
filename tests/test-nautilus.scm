;;; nautilus app 测试："在此处打开终端"扩展栈与 Guix 特有断点的
;;; 修复契约（2026-09 VM 实测：loader 内嵌 python 看不见 profile
;;; 里的 gi → import 静默失败 → 菜单不出现）。
;;;
;;; 覆盖：
;;;   NA1  app 启用 + 扩展栈四个包（nautilus/gvfs/python-nautilus/
;;;        nautilus-open-any-terminal）；
;;;   NA2  会话级 PYTHONPATH 指向 profile site-packages，版本号从
;;;        pinned python 推导（不写死 "3.12"——python 版本漂移时
;;;        断言自动跟随）；
;;;   NA3  gsettings terminal = ghostty（唯一 terminal 事实）。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg gsettings model) ; gsettings-setting-*
             (guixcfg users user)      ; %primary-user、user-profile-home-directory
             (gnu packages python)     ; python（版本推导）
             (guix packages)           ; package-version
             (gnu home services)       ; home-environment-variables-service-type
             (gnu services)            ; service-kind、service-value、service-type-extensions、service-extension-target
             (ice-9 rdelim)            ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "nautilus")

(define (app-by-name name)
  (find (lambda (a) (eq? name (application-name a))) %applications))

(define %nautilus-app (app-by-name 'nautilus))

;; simple-service 的 kind 是包装 type（extension 指向真实 target）——
;; 按 extension target 识别贡献类别（test-gnupg 同款模式）。
(define (env-vars app)
  (append-map service-value
              (filter (lambda (s)
                        (any (lambda (ext)
                               (eq? home-environment-variables-service-type
                                    (service-extension-target ext)))
                             (service-type-extensions (service-kind s))))
                      (application-home-services app))))

(define (expected-python-major-minor)
  (string-join (take (string-split (package-version python) #\.) 2)
               "."))

;; ── NA1：app 启用 + 扩展栈 ──────────────────────────────────
(test-assert "NA1: nautilus app enabled with the extension stack packages"
             (let ((names (map package-name
                               (application-home-packages %nautilus-app))))
               (and %nautilus-app
                    (application? %nautilus-app)
                    (member "nautilus" names)
                    (member "gvfs" names)
                    (member "python-nautilus" names)
                    (member "nautilus-open-any-terminal" names))))

;; ── NA2：PYTHONPATH（版本推导，不写死）──────────────────────
(test-assert "NA2: session PYTHONPATH points at the profile site-packages \
of the pinned python major.minor"
             (let* ((vars (env-vars %nautilus-app))
                    (entry (assoc "PYTHONPATH" vars))
                    (expected (string-append
                               (user-profile-home-directory %primary-user)
                               "/.guix-home/profile/lib/python"
                               (expected-python-major-minor)
                               "/site-packages")))
               (and entry
                    (= 1 (length vars))
                    (string=? expected (cdr entry)))))

(test-assert "NA2: python version is derived, not hardcoded"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/nautilus/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "(package-version python)")
                    (not (string-contains s "python3.12")))))

;; ── NA3：terminal 选择 gsettings ───────────────────────────
(test-assert "NA3: terminal gsettings is ghostty (single terminal fact)"
             (let ((gs (application-gsettings %nautilus-app)))
               (and (= 1 (length gs))
                    (string=? "com.github.stunkymonkey.nautilus-open-any-terminal"
                              (gsettings-setting-schema (car gs)))
                    (string=? "terminal"
                              (gsettings-setting-key (car gs)))
                    (string=? "'ghostty'"
                              (gsettings-setting-value (car gs))))))

;; ── NA4：ghostty bundled 扩展遮蔽（防重复菜单项）────────────
;; saayix ghostty 包随包分发自己的 nautilus-python 扩展
;; （"Open in Ghostty"，不可配置、总是新进程）——与 open-any-terminal
;; 重复。nautilus-python 先扫 ~/.local/share 且按 basename 走模块
;; 缓存，仓库 stub 遮蔽之；不采用 patch ghostty 包（zig 重建代价）。
(test-assert "NA4: repo stub shadows the saayix ghostty nautilus extension"
             (let* ((files
                     (append-map service-value
                                 (filter
                                  (lambda (s)
                                    (any (lambda (ext)
                                           (eq? home-files-service-type
                                                (service-extension-target ext)))
                                         (service-type-extensions
                                          (service-kind s))))
                                  (application-home-services %nautilus-app))))
                    (entry (assoc
                            ".local/share/nautilus-python/extensions/ghostty.py"
                            files))
                    (s (call-with-input-file
                        "modules/guixcfg/apps/nautilus/definition.scm"
                        (lambda (p) (read-string p)))))
               (and entry
                    ;; object->string：跨编译单元的 record 类型实例可能
                    ;; 不一致（plain-file? 陷阱），字符串断言与之无关。
                    (string-contains (object->string (cdr entry))
                                     "Shadows")
                    (string-contains s "basename"))))

(test-end "nautilus")
