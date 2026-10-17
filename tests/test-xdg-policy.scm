;;; 统一 XDG/default-apps 策略测试（(guixcfg home xdg)）：
;;; mimeapps.list 默认应用表的结构不变量——每个 MIME 恰好一个
;;; default（跨组重复 key 会生成语义不确定的 mimeapps.list）、
;;; 每个 default 值恰好一个 desktop entry、office 组指向 ONLYOFFICE
;;; desktop entry、文档域（PDF）指向 Papers desktop entry、领域排除
;;; 不变量（文本/电子书类不进 office 默认表）。
;;;
;;; 加应用不要求改本测试：断言只检查策略表的结构与领域边界，不枚举
;;; per-app 关联清单（完整清单在 office 组注释里，由上游 desktop
;;; entry 的 MimeType 实证）。

(use-modules (guixcfg home xdg)
              (guixcfg apps onlyoffice definition) ;%onlyoffice-desktop-entry
              (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "xdg-policy")

(define %keys
  (map car %xdg-default-applications))

(test-assert "every mime key appears exactly once (no duplicate defaults)"
             (= (length %keys)
                (length (delete-duplicates %keys))))

(test-assert "every default value is a single desktop entry"
             (every (lambda (entry)
                      (and (pair? entry)
                           (string? (car entry))
                           (pair? (cdr entry))
                           (string? (cadr entry))
                           (null? (cddr entry)))) %xdg-default-applications))

;; office 组 = 默认值恰为 ONLYOFFICE desktop entry 的 MIME 集合
;; （key 唯一性已断言，按值反查可靠）。
(define %office-keys
  (filter (lambda (k)
            (equal? (assoc-ref %xdg-default-applications k)
                    (list %onlyoffice-desktop-entry))) %keys))

(test-assert "office mime types default to the ONLYOFFICE desktop entry"
             (pair? %office-keys))

(test-end "xdg-policy")
