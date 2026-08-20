;;; ghostty application unit 测试（apps/ghostty/definition.scm）。
;;;
;;; 覆盖：
;;;   1.  %ghostty 在 registry；
;;;   2.  package contribution：来自 (saayix packages terminals) 的
;;;       稳定版 `ghostty`（name 精确为 "ghostty"，不是
;;;       ghostty-latest）；
;;;   3-4. 恰好一个 home service：config.ghostty 经
;;;       home-xdg-configuration-files 声明到 ghostty/config.ghostty
;;;       （~/.config/ghostty/config.ghostty），source-relative
;;;       local-file colocate apps/ghostty/；
;;;   5.  配置文件内容包含约定的键（keybind/selection-clear-on-copy/
;;;       font-family ×3/adjust-cell-height/window-padding）；
;;;   6.  无 persistence / 无 secrets / 无 system services（配置是
;;;       声明式 derived state，不持久化）；
;;;   7.  端到端：含 %ghostty 的 home 可 lower，生成
;;;       .config/ghostty/config.ghostty 且内容一致；
;;;   8.  无 CWD/checkout 依赖。

(use-modules (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg apps ghostty definition)
             (gnu home)                     ; home-environment
             (gnu home services)            ; home-xdg-configuration-files-service-type
             (gnu services)                 ; service-kind、service-value、service-extension-target
             (guix store)                   ; open-connection
             (guix monads)                  ; run-with-store
             (guix derivations)             ; derivation->output-path
             (guix gexp)                    ; lower-object、local-file-absolute-file-name
             (guix packages)                ; package-name、package-version
             (ice-9 rdelim)                 ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "ghostty")

;; ── 1：registry ─────────────────────────────────────────────
(define ghostty-app
  (find (lambda (a) (eq? 'ghostty (application-name a)))
        %applications))

(test-assert "ghostty is in the registry"
             (and ghostty-app (application? ghostty-app)))

(test-assert "foot is removed from the registry"
             (not (any (lambda (a) (eq? 'foot (application-name a)))
                       %applications)))

;; ── 2：package contribution（稳定版，非 latest）──────────────
(test-assert "ghostty stable package contributed via home-packages"
             (member "ghostty"
                     (map package-name (application-home-packages ghostty-app))))

(test-assert "the contributed package is NOT ghostty-latest"
             (every (lambda (p) (not (string=? "ghostty-latest" (package-name p))))
                    (application-home-packages ghostty-app)))

(test-assert "stable version is a release version (no -g<rev> suffix)"
             (let ((v (package-version
                       (car (application-home-packages ghostty-app)))))
               (and (string? v) (> (string-length v) 0)
                    (not (string-contains v "-g")))))

;; ── 3-4：config.ghostty 声明 ────────────────────────────────
(define xdg-svc
  (find (lambda (s)
          (any (lambda (ext)
                 (eq? (service-extension-target ext)
                      home-xdg-configuration-files-service-type))
               (service-type-extensions (service-kind s))))
        (application-home-services ghostty-app)))

(test-assert "exactly one home service (config via XDG files)"
             (= 1 (length (application-home-services ghostty-app))))

(test-assert "ghostty declares config.ghostty via home-xdg-configuration-files"
             (and xdg-svc
                  (assoc "ghostty/config.ghostty" (service-value xdg-svc))))

(test-assert "config is a source-relative local-file under apps/ghostty/"
             (let* ((lf (cadr (assoc "ghostty/config.ghostty"
                                     (service-value xdg-svc))))
                    (abs (local-file-absolute-file-name lf)))
               (and (local-file? lf)
                    (string-suffix? "/modules/guixcfg/apps/ghostty/config.ghostty"
                                    abs)
                    (file-exists? abs))))

;; ── 5：配置文件内容 ─────────────────────────────────────────
(define %config-content
  (call-with-input-file "modules/guixcfg/apps/ghostty/config.ghostty"
                        (lambda (p) (read-string p))))

(test-assert "config contains the copy keybind"
             (string-contains %config-content
                              "keybind = performable:ctrl+c=copy_to_clipboard"))
(test-assert "config contains selection-clear-on-copy"
             (string-contains %config-content
                              "selection-clear-on-copy = true"))
(test-assert "config contains the font fallback chain (Sarasa + emoji)"
             (and (string-contains %config-content
                                   "font-family = Sarasa Term SC Nerd")
                  (string-contains %config-content
                                   "font-family = Noto Color Emoji")))
(test-assert "config contains cell height and window padding"
             (and (string-contains %config-content "adjust-cell-height = 5%")
                  (string-contains %config-content "window-padding-x = 4")
                  (string-contains %config-content "window-padding-y = 4")))

;; ── 6：无 persistence / secrets / system services ───────────
(test-assert "ghostty declares no persistence"
             (null? (application-persistence ghostty-app)))
(test-assert "ghostty declares no secrets"
             (null? (application-secrets ghostty-app)))
(test-assert "ghostty declares no system services"
             (null? (application-system-services ghostty-app)))

;; ── 7：端到端生成 ───────────────────────────────────────────
(define %ghostty-home
  (home-environment
   (packages '())
   (services (applications-home-services (list %ghostty)))))

(define %store (open-connection))
(define %ghostty-drv (run-with-store %store (lower-object %ghostty-home)))
(build-derivations %store (list %ghostty-drv))
(define %ghostty-out (derivation->output-path %ghostty-drv))

(define %ghostty-config-file
  (string-append %ghostty-out "/files/.config/ghostty/config.ghostty"))

(test-assert "config.ghostty generated at .config/ghostty/config.ghostty"
             (file-exists? %ghostty-config-file))

(test-assert "generated config matches the source content"
             (let ((generated (call-with-input-file %ghostty-config-file
                                                    (lambda (p) (read-string p)))))
               (string=? generated %config-content)))

;; ── 8：无 CWD/checkout 依赖 ─────────────────────────────────
(test-assert "ghostty definition has no CWD/checkout dependence"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/ghostty/definition.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "getcwd"))
                    (not (string-contains s "current-filename"))
                    (not (string-contains s "/home/")))))

(test-end "ghostty")
