;;; 文档防漂移测试（targeted contract，同 test-source-hygiene 模式：
;;; 只检查明确的 contract，不做脆弱大 grep）。
;;;
;;; 覆盖：
;;;   1. docs 不再出现已删除的 hosts/vm-secrets.scm（inventory 是
;;;      hosts/vm.scm 内的 %vm-test-secrets）；
;;;   2. docs 不再把 %persistent-home-mount-options 归给
;;;      utils/home-path（authority 是 (guixcfg system
;;;      mount-metadata)）；
;;;   3. overview.md 不再出现已退出的 "PAM 登录 keyring" 描述；
;;;   4. docs 不再出现旧名 %vm-secrets（当前事实 %vm-test-secrets）；
;;;   5. docs 中反引号引用的关键仓库 .scm 路径存在（按仓库常见
;;;      相对前缀解析；占位符/通配/上游/运行时路径显式豁免）。

(use-modules (ice-9 ftw)      ; scandir
             (ice-9 rdelim)   ; read-string
             (ice-9 regex)    ; regexp-exec
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (md-files-under dir)
  (let loop ((dir dir))
    (append-map (lambda (e)
                  (let ((p (string-append dir "/" e)))
                    (cond ((string-suffix? ".md" e) (list p))
                      ((and (not (string-prefix? "." e))
                            (eq? 'directory (stat:type (stat p))))
                       (loop p))
                      (else '()))))
                (or (false-if-exception (scandir dir)) '()))))

(define %doc-files (md-files-under "docs"))
(define %docs-content
  (string-join (map (lambda (f)
                      (call-with-input-file f
                        (lambda (p) (read-string p))))
                    %doc-files)
               "\n"))

(define (doc-file-content name)
  (call-with-input-file name (lambda (p) (read-string p))))

;; 反引号 .scm 引用的存在性检查豁免：上游/仓库外路径、boot 产物
;; 路径、占位符、散文术语，以及文档中作为删除决策记录的路径。
(define %doc-path-exemptions
  '("definition.scm" "state.scm" "limine-menu.scm"
    "EFI/Guix/candidate.scm" "gnu/build/file-systems.scm"
    "guix/gexp.scm" "nonguix/transformations.scm"
    "modules/guixcfg/system/resolvconf.scm")) ; dns.md 的删除决策记录

;; modules/guixcfg 下的全部文件 basename（bare-name 引用的兜底解析：
;; docs 常用 `readiness.scm` 等不带 area 前缀的短名）。
(define %guixcfg-basenames
  (let loop ((dir "modules/guixcfg"))
    (append-map (lambda (e)
                  (let ((p (string-append dir "/" e)))
                    (cond ((string-suffix? ".scm" e) (list e))
                      ((and (not (string-prefix? "." e))
                            (eq? 'directory (stat:type (stat p))))
                       (loop p))
                      (else '()))))
                (or (false-if-exception (scandir dir)) '()))))

(define (repo-scm-path-exists? path)
  "PATH（相对引用）按仓库常见前缀解析后存在；或 basename 唯一命中
modules/guixcfg 下的某个文件（bare-name 引用）。"
  (or (member path %doc-path-exemptions)
      (any file-exists?
           (list path
                 (string-append "modules/" path)
                 (string-append "modules/guixcfg/" path)
                 (string-append "modules/guixcfg/flatpak/" path)
                 (string-append "tools/" path)
                 (string-append "tests/" path)))
      (member (basename path) %guixcfg-basenames)))

(define (backtick-scm-refs content)
  "CONTENT 中反引号包裹的 .scm 相对引用（跳过占位符/通配/绝对路径/
含空格命令）。"
  (let ((rx (make-regexp "`([^` ]*\\.scm)`")))
    (let loop ((content content) (acc '()))
      (let ((m (regexp-exec rx content)))
        (if (not m)
          (reverse acc)
          (let ((p (match:substring m 1)))
            (loop (match:suffix m)
                  (if (or (string-contains p "<")
                          (string-contains p ">")
                          (string-contains p "*")
                          (string-prefix? "/" p))
                    acc
                    (cons p acc)))))))))

(test-begin "doc-hygiene")

(test-assert "docs never reference the removed hosts/vm-secrets.scm"
             (not (string-contains %docs-content "vm-secrets.scm")))

(test-assert "docs never attribute %persistent-home-mount-options to utils/home-path"
             ;; authority 是 (guixcfg system mount-metadata)；按行
             ;; 检查（docs 一句一行），避免跨句误报。
             (not (any (lambda (line)
                         (and (string-contains line "%persistent-home-mount-options")
                              (string-contains line "home-path")))
                       (string-split %docs-content #\newline))))

(test-assert "overview.md no longer describes a PAM login keyring"
             (not (string-contains
                   (doc-file-content "docs/architecture/overview.md")
                   "PAM 登录 keyring")))

(test-assert "docs use the current %vm-test-secrets name (no stale %vm-secrets)"
             (not (regexp-exec (make-regexp "%vm-secrets([^-]|$)")
                               %docs-content)))

(test-assert "backtick-quoted repository .scm paths in docs exist"
             (let ((missing
                    (filter (lambda (p)
                              (not (repo-scm-path-exists? p)))
                            (delete-duplicates
                             (backtick-scm-refs %docs-content)))))
               (when (pair? missing)
                 (format (current-error-port)
                         "doc-hygiene: unresolved .scm references: ~s~%"
                         missing))
               (null? missing)))

(test-end "doc-hygiene")
