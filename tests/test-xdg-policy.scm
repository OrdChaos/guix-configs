;;; 统一 XDG/default-apps 策略测试（(guixcfg home xdg)）：
;;; mimeapps.list 默认应用表的结构不变量——每个 MIME 恰好一个
;;; default（跨组重复 key 会生成语义不确定的 mimeapps.list）、
;;; 每个 default 值恰好一个 desktop entry、office 组指向 ONLYOFFICE
;;; desktop entry、领域排除不变量（文本/电子书类不进 office 默认表）。
;;;
;;; 加应用不要求改本测试：断言只检查策略表的结构与领域边界，不枚举
;;; per-app 关联清单（完整清单在 office 组注释里，由上游 desktop
;;; entry 的 MimeType 实证）。

(use-modules (guixcfg home xdg)
             (guixcfg apps onlyoffice definition) ; %onlyoffice-desktop-entry
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "xdg-policy")

(define %keys (map car %xdg-default-applications))

(test-assert "every mime key appears exactly once (no duplicate defaults)"
             (= (length %keys) (length (delete-duplicates %keys))))

(test-assert "every default value is a single desktop entry"
             (every (lambda (entry)
                      (and (pair? entry)
                           (string? (car entry))
                           (pair? (cdr entry))
                           (string? (cadr entry))
                           (null? (cddr entry))))
                    %xdg-default-applications))

;; office 组 = 默认值恰为 ONLYOFFICE desktop entry 的 MIME 集合
;; （key 唯一性已断言，按值反查可靠）。
(define %office-keys
  (filter (lambda (k)
            (equal? (assoc-ref %xdg-default-applications k)
                    (list %onlyoffice-desktop-entry)))
          %keys))

(test-assert "office mime types default to the ONLYOFFICE desktop entry"
             (pair? %office-keys))

(test-assert "core office formats are covered (docx/xlsx/pptx/odt/pdf/csv)"
             (every (lambda (m) (member m %office-keys))
                    '("application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                      "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                      "application/vnd.oasis.opendocument.text"
                      "application/pdf"
                      "text/csv")))

;; ONLYOFFICE 声明集含 WPS 原生格式（wps/et/dps——它声明可打开）。
(test-assert "wps-native formats are covered (onlyoffice declares them)"
             (every (lambda (m) (member m %office-keys))
                    '("application/wps-office.wps"
                      "application/wps-office.et"
                      "application/wps-office.dps")))

;; 领域排除（office 组注释声明的边界）：文本编辑器域与电子书/图像
;; 域不得进 office 默认表（text/plain 已由 GNOME Text Editor 默认）。
(test-assert "editor/ebook domain types are not office defaults"
             (every (lambda (m) (not (member m %office-keys)))
                    '("text/plain"
                      "text/markdown"
                      "application/epub+zip"
                      "application/x-fictionbook+xml"
                      "image/vnd.djvu")))

;; desktop entry 事实 single source：策略消费的常量来自应用
;; definition（virelith 包 install-plan 实证）。
(test-equal "office desktop entry is the onlyoffice one"
            "onlyoffice-desktopeditors.desktop"
            %onlyoffice-desktop-entry)

(test-end "xdg-policy")
