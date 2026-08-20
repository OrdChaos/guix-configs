;;; 统一 XDG / default-applications 策略测试（modules/guixcfg/home/
;;; xdg.scm）：用户级默认应用选择（MIME associations、URL scheme
;;; handlers、默认浏览器）由本模块拥有；应用模块只提供 desktop
;;; entry 纯数据常量。职责边界：application owns application state;
;;; XDG layer owns default-application policy.
;;;
;;; 覆盖：
;;;   1.  %xdg-default-applications：恰好四个浏览器 MIME 类型，全部
;;;       指向 %chrome-desktop-entry（跨模块常量，不复制字符串）；
;;;   2.  %xdg-default-apps-service 是 simple-service，extension 目标
;;;       是官方 home-xdg-mime-applications-service-type，config 的
;;;       default 字段 = %xdg-default-applications（added/removed 空）；
;;;   3.  端到端：含该服务的 home 可 lower，生成 .config/mimeapps.list
;;;       且含 [Default Applications] 四行；
;;;   4.  策略字面（text/html、x-scheme-handler/...）只出现在
;;;       home/xdg.scm，不出现于 Chrome 模块（test-google-chrome.scm
;;;       反向断言）；
;;;   5.  无 imperative xdg-mime 命令、无 mimeapps.list persistence、
;;;       无应用依赖反向（xdg → app metadata 单向）。

(use-modules (guixcfg home xdg)             ; %xdg-default-applications、service
             (guixcfg apps google-chrome-stable definition) ; %chrome-desktop-entry
             (guixcfg apps model)
             (gnu home)                     ; home-environment
             (gnu home services xdg)        ; home-xdg-mime-applications-*
             (gnu services)                 ; service-kind、service-value、service-extension-target
             (guix store)                   ; open-connection
             (guix monads)                  ; run-with-store
             (guix derivations)             ; derivation->output-path
             (guix gexp)                    ; lower-object
             (ice-9 rdelim)                 ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "xdg-default-apps")

;; ── 1：default-applications 策略数据 ────────────────────────
(test-assert "exactly the four browser MIME types"
             (equal? '("text/html"
                       "application/xhtml+xml"
                       "x-scheme-handler/http"
                       "x-scheme-handler/https")
                     (map car %xdg-default-applications)))

(test-assert "every association points to the chrome desktop-entry constant"
             (every (lambda (e) (equal? (list %chrome-desktop-entry) (cdr e)))
                    %xdg-default-applications))

(test-assert "desktop entry constant is the verified chrome entry"
             (string=? %chrome-desktop-entry "google-chrome.desktop"))

;; ── 2：service 结构与配置 ───────────────────────────────────
(test-assert "%xdg-default-apps-service is a service"
             (service? %xdg-default-apps-service))

(test-assert "service extends the official home-xdg-mime-applications type"
             (any (lambda (ext)
                    (eq? (service-extension-target ext)
                         home-xdg-mime-applications-service-type))
                  (service-type-extensions (service-kind %xdg-default-apps-service))))

(define xdg-config (service-value %xdg-default-apps-service))
(define config-default
  ((@@ (gnu home services xdg)
       home-xdg-mime-applications-configuration-default)
   xdg-config))
(define config-added
  ((@@ (gnu home services xdg)
       home-xdg-mime-applications-configuration-added)
   xdg-config))

(test-assert "service config default = %xdg-default-applications"
             (equal? %xdg-default-applications config-default))

(test-assert "added/removed empty (only Default Applications)"
             (null? config-added))

;; ── 3：端到端生成 .config/mimeapps.list ─────────────────────
(define %xdg-home
  (home-environment
   (packages '())
   (services (list %xdg-default-apps-service))))

(define %store (open-connection))
(define %xdg-drv (run-with-store %store (lower-object %xdg-home)))
(build-derivations %store (list %xdg-drv))
(define %xdg-out (derivation->output-path %xdg-drv))

(test-assert "xdg-only home lowers"
             (and %xdg-out (file-exists? %xdg-out)))

(define %mimeapps-file
  (string-append %xdg-out "/files/.config/mimeapps.list"))

(test-assert "mimeapps.list generated at .config/mimeapps.list"
             (file-exists? %mimeapps-file))

(define %mimeapps-content
  (call-with-input-file %mimeapps-file
                        (lambda (p) (read-string p))))

(test-assert "mimeapps.list has the [Default Applications] section"
             (string-contains %mimeapps-content
                              "[Default Applications]"))

(for-each
 (lambda (mime)
   (test-assert (string-append "mimeapps.list declares default for " mime)
                (string-contains %mimeapps-content
                                 (string-append mime "=google-chrome.desktop"))))
 '("text/html"
   "application/xhtml+xml"
   "x-scheme-handler/http"
   "x-scheme-handler/https"))

;; ── 4：策略字面位于本模块 ───────────────────────────────────
(test-assert "policy literals live in home/xdg.scm"
             (let ((s (call-with-input-file "modules/guixcfg/home/xdg.scm"
                                           (lambda (p) (read-string p)))))
               (and (string-contains s "text/html")
                    (string-contains s "application/xhtml+xml")
                    (string-contains s "x-scheme-handler/http")
                    (string-contains s "x-scheme-handler/https"))))

;; ── 5：无 imperative / 无 persistence / 无反向依赖 ──────────
(test-assert "no imperative xdg-mime default command in the module"
             (let ((s (call-with-input-file "modules/guixcfg/home/xdg.scm"
                                           (lambda (p) (read-string p)))))
               (not (string-contains s "xdg-mime default"))))

(test-assert "xdg module declares no persistence (no application-persistence)"
             (let ((s (call-with-input-file "modules/guixcfg/home/xdg.scm"
                                           (lambda (p) (read-string p)))))
               (not (string-contains s "application-persistence"))))

(test-assert "dependency is one-way: chrome module does not import this module"
             (let ((s (call-with-input-file
                       "modules/guixcfg/apps/google-chrome-stable/definition.scm"
                       (lambda (p) (read-string p)))))
               (not (string-contains s
                                     "#:use-module (guixcfg home xdg)"))))

(test-end "xdg-default-apps")
