;;; VS Code application unit 测试（apps/vscode/definition.scm）。
;;;
;;; 背景：无状态重启后 UI 回退英语的根因是 VS Code 早期 NLS 初始化
;;; 依赖 application-owned ~/.config/Code/languagepacks.json
;;; （仅 ~/.vscode/extensions/ 持久化 + argv.json locale=zh-cn 不足
;;; 以恢复非英语 UI——pinned 1.134.0 main.js / cliProcessMain.js 审计，
;;; 见 definition.scm 头注释）。修复 = generic bind-file exposure +
;;; vscode 两条新 rule。
;;;
;;; 覆盖：
;;;   VC1  app 启用；persistence 恰好 5 条（extensions rule 已于
;;;        2026-10-04 随不可变扩展模型落地后移除）；无
;;;        整体 ~/.config/Code consumer；ephemeral 路径不持久化；
;;;   VC2  languagepacks.json → bind-file（单文件 application-owned）；
;;;        clp/ → bind-directory（derived cache）；
;;;   VC3  %vm-os 生成 file→file bind（create-mount-point? #f）；
;;;        bind-directory 保持 #t；device 全部指向
;;;        /persist/data-app/vscode/...；
;;;   VC4  repo-owned 声明式文件：argv.json 三字段
;;;        （enable-crash-reporter=false / password-store /
;;;        locale=zh-cn）、settings.json、keybindings.json 经
;;;        home-files 声明；
;;;   VC5  languagepacks.json / clp 不被仓库生成（非 home-files
;;;        target——VS Code 自维护的 mutable state / derived cache）。

(use-modules (guixcfg hosts vm) ;%vm-os（assembly 真实接线）
             (guixcfg apps model)
             (guixcfg apps registry) ;%applications
             (guixcfg apps vscode extensions) ;%vscode-extensions
             (guixcfg system application-persistence) ;rule accessors
             (guixcfg users user) ;%primary-user
             (guix packages) ;package-name/-version/-properties
             (gnu home services) ;home-files-service-type
             (gnu system) ;operating-system-file-systems
             (gnu system file-systems) ;file-system-*
             (gnu services)
             (virelith packages vscode-extensions) ;vscode-extension-package?
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "vscode")

(define (app-by-name name)
  (find (lambda (a)
          (eq? name
               (application-name a))) %applications))

(define %vscode-app
  (app-by-name 'vscode))

(define (rule-by-name name)
  (find (lambda (r)
          (eq? name
               (application-persistence-rule-name r)))
        (application-persistence %vscode-app)))

(define (vscode-home-file-targets)
  "home-files 声明目标的全部 target 列表（.config 与 HOME dotfile）。"
  (append-map (lambda (svc)
                (map car
                     (service-value svc)))
              (application-home-services %vscode-app)))

;; ── VC1：app 启用、persistence 恰好 5 条、无整体/临时持久化 ──
(test-assert
 "VC1: persistence rules retained (extensions rule removed 2026-10-04)"
 (and (not (rule-by-name 'extensions))
      (rule-by-name 'global-storage)
      (rule-by-name 'workspace-storage)
      (rule-by-name 'local-history)))

(test-assert
 "VC1: no whole ~/.config/Code consumer (logs/caches stay ephemeral)"
 (every (lambda (r)
          (not (string=? ".config/Code"
                         (application-persistence-rule-consumer r))))
        (application-persistence %vscode-app)))

;; ephemeral 边界：logs/CachedData/CachedExtensionVSIXs/Cache*/
;; GPUCache/Dawn*/~/.cache/Code 一律不得成为 consumer
(test-assert "VC1: ephemeral paths are not persisted"
             (let ((consumers (map application-persistence-rule-consumer
                                   (application-persistence %vscode-app))))
               (every (lambda (c)
                        (not (or (string-prefix? ".config/Code/logs" c)
                                 (string-prefix? ".config/Code/CachedData" c)
                                 (string-prefix?
                                  ".config/Code/CachedExtensionVSIXs" c)
                                 (string-prefix? ".config/Code/Cache" c)
                                 (string-prefix? ".config/Code/GPUCache" c)
                                 (string-prefix? ".config/Code/Dawn" c)
                                 (string-prefix? ".cache/Code" c)))) consumers)))

;; ── VC2：languagepacks.json → bind-file；clp/ → bind-directory ──
(test-assert "VC2: languagepacks.json is a bind-file application-owned rule"
             (let ((r (rule-by-name 'language-packs)))
               (and r
                    (string=? "vscode/languagepacks.json"
                              (application-persistence-rule-backing r))
                    (string=? ".config/Code/languagepacks.json"
                              (application-persistence-rule-consumer r))
                    (eq? 'bind-file
                         (application-persistence-rule-exposure r))
                    (eq? 'application-owned
                         (application-persistence-rule-lifecycle r)))))

(test-assert "VC2: clp/ is a bind-directory application-owned rule"
             (let ((r (rule-by-name 'language-pack-cache)))
               (and r
                    (string=? "vscode/clp"
                              (application-persistence-rule-backing r))
                    (string=? ".config/Code/clp"
                              (application-persistence-rule-consumer r))
                    (eq? 'bind-directory
                         (application-persistence-rule-exposure r))
                    (eq? 'application-owned
                         (application-persistence-rule-lifecycle r)))))

;; ── VC3：%vm-os 真实接线（file→file bind + create-mount-point?）──
(define %vscode-mounts
  (filter (lambda (fs)
            (and (string-prefix? "/persist/data-app/vscode/"
                                 (file-system-device fs))))
          (operating-system-file-systems %vm-os)))

(test-equal "VC3: five vscode bind mounts declared in %vm-os" 5
            (length %vscode-mounts))

(test-assert
 "VC3: languagepacks.json mounts file→file with create-mount-point? #f"
 (let ((fs (find (lambda (f)
                   (string-suffix? "/languagepacks.json"
                                   (file-system-mount-point f)))
                 %vscode-mounts)))
   (and fs
        (string=? "/persist/data-app/vscode/languagepacks.json"
                  (file-system-device fs))
        (string=? (string-append (user-profile-home-directory %primary-user)
                                 "/.config/Code/languagepacks.json")
                  (file-system-mount-point fs))
        (eq? 'bind-mount
             (car (file-system-flags fs)))
        (not (file-system-create-mount-point? fs)))))

(test-assert "VC3: clp mounts directory→directory with create-mount-point? #t"
 (let ((fs (find (lambda (f)
                   (string-suffix? "/clp"
                                   (file-system-mount-point f)))
                 %vscode-mounts)))
   (and fs
        (string=? "/persist/data-app/vscode/clp"
                  (file-system-device fs))
        (file-system-create-mount-point? fs))))

(test-assert
 "VC3: original three directory mounts keep create-mount-point? #t"
 (let ((mounts (filter (lambda (f)
                         (not (or (string-suffix? "/languagepacks.json"
                                                  (file-system-mount-point f))
                                  (string-suffix? "/clp"
                                                  (file-system-mount-point f)))))
                       %vscode-mounts)))
   (and (= 3
           (length mounts))
        (every file-system-create-mount-point? mounts))))

;; ── VC4：repo-owned 声明式文件 ──────────────────────────────
(test-assert "VC4: argv.json declared via home-files"
             (member ".vscode/argv.json"
                     (vscode-home-file-targets)))
(test-assert "VC4: settings.json / keybindings.json declared via home-files"
             (and (member ".config/Code/User/settings.json"
                          (vscode-home-file-targets))
                  (member ".config/Code/User/keybindings.json"
                          (vscode-home-file-targets))))

;; ── VC5：languagepacks.json / clp 不是仓库声明式文件 ────────
;; app-owned mutable state / derived cache：绝不能经 home-files 生成
;; （VS Code 自维护；单文件 bind 投影到 backing）。
(test-assert "VC5: languagepacks.json is NOT a repo-owned home-files target"
             (not (member ".config/Code/languagepacks.json"
                          (vscode-home-file-targets))))
(test-assert "VC5: clp is NOT a repo-owned home-files target"
             (not (member ".config/Code/clp"
                          (vscode-home-file-targets))))

;; ── VC6：不可变扩展集合（vscode-with-extensions）──────────────
;; 架构不变量：home-packages 含且仅含一个 wrapper 包（裸 vscode 与
;; wrapper 并存会 bin/desktop 冲突——单 wrapper 是显式约束）；声明
;; 集合恰为 extensions.scm 的 8 个 id（含 zh-hans 语言包——不可变
;; 集合下语言包必须声明式提供；含 rust-analyzer——platform-specific
;; linux-x64 variant，server 走 PATH；含 clangd——纯 JS 前端，后端
;; 走 PATH 的 clang-toolchain）；扩展版本/hash pin 于
;; extensions.scm。scheme-lsp 与 guile-lsp-server 已于 2026-10-04
;; 移除（LSP 体验不佳）。
(define %vscode-home-packages
  (application-home-packages %vscode-app))

(define (package-named name)
  (find (lambda (p)
          (string=? name
                    (package-name p))) %vscode-home-packages))

(test-assert "VC6: exactly one vscode-with-extensions wrapper, no bare vscode"
 (and (package-named "vscode-with-extensions")
      (not (package-named "vscode"))))
(test-equal "VC6: wrapper declares exactly the eight pinned extension ids"
            '("astro-build.astro-vscode" "huytd.nord-light"
              "llvm-vs-code-extensions.vscode-clangd"
              "lxl66566.anyformatter-vscode"
              "MS-CEINTL.vscode-language-pack-zh-hans"
              "rust-lang.rust-analyzer"
              "tamasfe.even-better-toml"
              "tsyesika.guile-scheme-enhanced")
            (assoc-ref (package-properties (package-named
                                            "vscode-with-extensions"))
                       'vscode-extension-ids))

(test-assert
 "VC6: rust-analyzer extension pins the linux-x64 platform variant"
 (let ((ra (find (lambda (ext)
                   (string-ci=? "rust-lang.rust-analyzer"
                                (vscode-extension-package-id ext)))
                 %vscode-extensions)))
   (and ra
        (string=? "linux-x64"
                  (assoc-ref (package-properties ra)
                             'vscode-extension-platform)))))

(test-assert
 "VC6: every declared extension carries id property and pinned version"
 (every (lambda (ext)
          (and (vscode-extension-package? ext)
               (string? (vscode-extension-package-id ext))
               (not (string-null? (package-version ext))))) %vscode-extensions))

(test-assert "VC6: zh-hans language pack is part of the declared set"
             (find (lambda (ext)
                     (string-ci=? "MS-CEINTL.vscode-language-pack-zh-hans"
                                  (vscode-extension-package-id ext)))
                   %vscode-extensions))

(test-assert "VC6: guile-lsp-server is gone with scheme-lsp"
             (not (package-named "guile-lsp-server")))

(test-end "vscode")
