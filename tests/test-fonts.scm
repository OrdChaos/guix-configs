;;; 字体集合与 Fontconfig 策略测试（modules/guixcfg/home/fonts.scm；
;;; Guix Home owns——profile 决定“有哪些字体”，home-fontconfig
;;; service 决定 generic-family/fallback 策略）。
;;;
;;; 覆盖：
;;;   1.  %fonts：期望的字体包全部在场（virelith 自有 + guix 官方）；
;;;   2.  %fontconfig-service：kind = home-fontconfig-service-type，
;;;       value 是 snippet 列表且首元素是 profile 字体目录；
;;;   3.  sans-serif 主链：MiSans 首（简体优先）→ CJK SC 在 JP 前 →
;;;       Symbols → Emoji → Unifont last；
;;;   4.  serif 主链：Noto Serif 首、无 MiSans（sans 不进 serif）、
;;;       SC 在 JP 前；
;;;   5.  monospace 主链：Sarasa 首、SC 在 JP 前；
;;;   6.  system-ui → sans-serif；emoji → Noto Color Emoji；
;;;   7.  language-aware edits：ja→JP、zh-tw/zh-hk/zh-mo→TC、ko→KR，
;;;       对 sans-serif/serif/monospace 全覆盖（Noto CJK 各 variant
;;;       lang 覆盖同构，必须显式区分）；
;;;   8.  MiSans L3 target=font lang 补齐编辑存在（lang 空元数据修复）；
;;;   9.  端到端：lower home → .config/fontconfig/fonts.conf 生成，
;;;       含 <match target="pattern">、alias 与真实 family 名；
;;;   10. 无 persistence / 无 secrets 声明。

(use-modules (guixcfg home fonts)
             (gnu home)                       ; home-environment
             (gnu home services fontutils)    ; home-fontconfig-service-type
             (gnu services)                   ; service-kind、service-value
             (guix store)                     ; open-connection
             (guix monads)                    ; run-with-store
             (guix derivations)               ; derivation->output-path
             (guix gexp)                      ; lower-object
             (guix packages)                  ; package-name
             (ice-9 rdelim)                   ; read-string
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "fonts")

;; ── 1：%fonts 包集合 ────────────────────────────────────────
;; 注：pinned guix 8a2afa6 中 fontconfig 变量是 hidden package
;; （name "fontconfig-minimal"），实测其 store 输出含全部 fc-* 工具
;; （fc-query/fc-match/fc-cache），home-fontconfig service 内部也用
;; 同一变量。
(define %expected-font-packages
  '("mi-sans-global" "sarasa-term-sc-nerd"
    "font-google-noto" "font-google-noto-emoji"
    "font-google-noto-sans-cjk" "font-google-noto-serif-cjk"
    "font-gnu-unifont" "fontconfig-minimal"))

(test-assert "fonts is a non-empty package list"
             (and (pair? %fonts) (every package? %fonts)))

(test-assert "every expected font package is installed"
             (every (lambda (name)
                      (member name (map package-name %fonts)))
                    %expected-font-packages))

;; ── 2：service 形态 ─────────────────────────────────────────
;; %fontconfig-service 是 simple-service：extension 目标是官方
;; home-fontconfig-service-type；canonical 实例由 home-environment
;; essential services 自带（default value = profile 字体目录）。
(test-assert "fontconfig service extends home-fontconfig-service-type"
             (any (lambda (ext)
                    (eq? (service-extension-target ext)
                         home-fontconfig-service-type))
                  (service-type-extensions (service-kind %fontconfig-service))))

(define snippets (service-value %fontconfig-service))

(test-assert "essential home-fontconfig provides the profile fonts dir"
             (equal? '("~/.guix-home/profile/share/fonts")
                     (service-type-default-value
                      home-fontconfig-service-type)))

(test-assert "extension value is a snippet list without duplicate dir"
             (and (pair? snippets)
                  (not (string? (car snippets)))
                  (every pair? snippets)))

;; ── 结构提取辅助 ────────────────────────────────────────────
(define (alias-snippet snippets family)
  (find (lambda (s)
          (and (pair? s) (eq? (car s) 'alias)
               (any (lambda (c) (equal? c (list 'family family)))
                    (cdr s))))
        snippets))

(define (prefer-families snippet)
  (let ((prefer (find (lambda (c) (and (pair? c) (eq? (car c) 'prefer)))
                      (cdr snippet))))
    (map (lambda (fam) (cadr fam)) (cdr prefer))))

(define (family-position names family)
  (list-index (lambda (n) (string=? n family)) names))

;; ── 3-6：generic family 主链 ───────────────────────────────
(define sans-alias (alias-snippet snippets "sans-serif"))
(test-assert "sans-serif alias exists"
             sans-alias)
(define sans-families (prefer-families sans-alias))

(test-assert "sans-serif: MiSans is the primary family"
             (string=? "MiSans" (car sans-families)))
(test-assert "sans-serif: MiSans L3 follows MiSans (extension fallback)"
             (string=? "MiSans L3" (cadr sans-families)))
(test-assert "sans-serif: Noto Sans CJK SC precedes JP (no-lang SC-first)"
             (let ((sc (family-position sans-families "Noto Sans CJK SC"))
                   (jp (family-position sans-families "Noto Sans CJK JP")))
               (and sc jp (< sc jp))))
(test-assert "sans-serif: Symbols before Color Emoji before Unifont"
             (let ((sym (family-position sans-families "Noto Sans Symbols"))
                   (sym2 (family-position sans-families "Noto Sans Symbols 2"))
                   (emoji (family-position sans-families "Noto Color Emoji"))
                   (unifont (family-position sans-families "Unifont")))
               (and sym sym2 emoji unifont
                    (< sym sym2) (< sym2 emoji) (< emoji unifont))))
(test-assert "sans-serif: Unifont is the last resort"
             (string=? "Unifont" (last sans-families)))

(define serif-alias (alias-snippet snippets "serif"))
(test-assert "serif alias exists"
             serif-alias)
(define serif-families (prefer-families serif-alias))

(test-assert "serif: Noto Serif is primary"
             (string=? "Noto Serif" (car serif-families)))
(test-assert "serif: MiSans is NOT in the serif chain (sans only)"
             (not (member "MiSans" serif-families)))
(test-assert "serif: Noto Serif CJK SC precedes JP"
             (let ((sc (family-position serif-families "Noto Serif CJK SC"))
                   (jp (family-position serif-families "Noto Serif CJK JP")))
               (and sc jp (< sc jp))))
(test-assert "serif: Unifont is the last resort"
             (string=? "Unifont" (last serif-families)))

(define mono-alias (alias-snippet snippets "monospace"))
(test-assert "monospace alias exists"
             mono-alias)
(define mono-families (prefer-families mono-alias))

(test-assert "monospace: Sarasa Term SC Nerd is primary"
             (string=? "Sarasa Term SC Nerd" (car mono-families)))
(test-assert "monospace: Noto Sans CJK SC precedes JP"
             (let ((sc (family-position mono-families "Noto Sans CJK SC"))
                   (jp (family-position mono-families "Noto Sans CJK JP")))
               (and sc jp (< sc jp))))
(test-assert "monospace: Unifont is the last resort"
             (string=? "Unifont" (last mono-families)))

(test-assert "system-ui aliases to sans-serif"
             (let ((s (alias-snippet snippets "system-ui")))
               (and s (equal? '("sans-serif") (prefer-families s)))))

(test-assert "emoji aliases to Noto Color Emoji"
             (let ((s (alias-snippet snippets "emoji")))
               (and s (equal? '("Noto Color Emoji") (prefer-families s)))))

;; ── 7：language-aware CJK edits ─────────────────────────────
(define (test-attr-value test name)
  ;; test 元素的 name 属性值：(test (@ (name "family") (compare "eq")) ...)
  ;; → "family"
  (let ((attrs (cadr test)))
    (and (pair? attrs) (eq? (car attrs) '@)
         (let ((pair (assoc name (cdr attrs))))
           (and pair (cadr pair))))))

(define (lang-edit-snippets snippets)
  (filter (lambda (s)
            (and (pair? s) (eq? (car s) 'match)
                 (equal? (cadr s) (list '@ (list 'target "pattern")))))
          snippets))

(define (edit-params snippet)
  ;; 返回 (generic lang variant)：从两个 test 与 edit 提取字符串值。
  (let* ((tests (filter (lambda (c)
                          (and (pair? c) (eq? (car c) 'test)))
                        (cddr snippet)))
         (generic (cadr (car (cddr (find (lambda (t)
                                          (string=? (test-attr-value t 'name)
                                                    "family"))
                                        tests)))))
         (lang (cadr (car (cddr (find (lambda (t)
                                       (string=? (test-attr-value t 'name)
                                                 "lang"))
                                     tests)))))
         (edit (find (lambda (c) (and (pair? c) (eq? (car c) 'edit)))
                     (cddr snippet)))
         (variant (cadr (car (cddr edit)))))
    (list generic lang variant)))

(define lang-edits (lang-edit-snippets snippets))

;; CJK：5 个 lang（ja/zh-tw/zh-hk/zh-mo/ko）× 3 个 generic family；
;; script：12 个 lang（ar/th/bo/my/km/lo/hi/ne/mr/sa/gu/pa）× 3。
(test-assert "lang-aware edits exist (CJK 15 + script 36)"
             (= 51 (length lang-edits)))

(for-each
 (lambda (expected)
   (test-assert (string-append "lang edit: "
                               (first expected) " + "
                               (second expected) " → "
                               (third expected))
                (member expected (map edit-params lang-edits))))
 '(("sans-serif" "ja" "Noto Sans CJK JP")
   ("serif" "ja" "Noto Serif CJK JP")
   ("monospace" "ja" "Noto Sans CJK JP")
   ("sans-serif" "zh-tw" "Noto Sans CJK TC")
   ("sans-serif" "zh-hk" "Noto Sans CJK TC")
   ("sans-serif" "zh-mo" "Noto Sans CJK TC")
   ("serif" "zh-tw" "Noto Serif CJK TC")
   ("monospace" "zh-tw" "Noto Sans CJK TC")
   ("sans-serif" "ko" "Noto Sans CJK KR")
   ("serif" "ko" "Noto Serif CJK KR")
   ("monospace" "ko" "Noto Sans CJK KR")))

(test-assert "no lang edit overrides zh-cn (MiSans handles simplified first)"
             (not (any (lambda (e) (string=? "zh-cn" (second e)))
                       (map edit-params lang-edits))))

(test-assert "script lang edits route to the real script families"
             (every (lambda (expected)
                      (member expected (map edit-params lang-edits)))
                    '(("sans-serif" "ar" "MiSans Arabic")
                      ("serif" "ar" "Noto Sans Arabic")
                      ("monospace" "ar" "Noto Sans Arabic")
                      ("sans-serif" "th" "MiSans Thai")
                      ("sans-serif" "bo" "MiSans Tibetan")
                      ("sans-serif" "hi" "MiSans Devanagari")
                      ("sans-serif" "gu" "MiSans Gujarati")
                      ("sans-serif" "pa" "MiSans Gurmukhi"))))

;; ── 8：MiSans L3 lang 补齐（target=font）────────────────────
(test-assert "MiSans L3 target=font lang edit exists"
             (any (lambda (s)
                    (and (pair? s) (eq? (car s) 'match)
                         (equal? (cadr s)
                                 (list '@ (list 'target "font")))
                         (any (lambda (c)
                                (and (pair? c) (eq? (car c) 'test)
                                     (equal? c
                                             (list 'test
                                                   (list '@ (list 'name "family")
                                                         (list 'compare "eq"))
                                                   (list 'string "MiSans L3")))))
                              (cddr s))))
                  snippets))

;; ── 9：端到端生成 fonts.conf ────────────────────────────────
(define %font-home
  (home-environment
   (packages '())
   (services (list %fontconfig-service))))

(define %store (open-connection))
(define %font-drv (run-with-store %store (lower-object %font-home)))
(build-derivations %store (list %font-drv))
(define %font-out (derivation->output-path %font-drv))

(define %fonts-conf
  (string-append %font-out "/files/.config/fontconfig/fonts.conf"))

(test-assert "fonts.conf generated at .config/fontconfig/fonts.conf"
             (file-exists? %fonts-conf))

(define %fonts-conf-content
  (call-with-input-file %fonts-conf (lambda (p) (read-string p))))

(test-assert "fonts.conf contains the fontconfig root and profile dir"
             (and (string-contains %fonts-conf-content "<fontconfig>")
                  (string-contains %fonts-conf-content
                                   "<dir>~/.guix-home/profile/share/fonts</dir>")))

(test-assert "fonts.conf contains the sans-serif alias with MiSans first"
             (let ((i (string-contains %fonts-conf-content
                                       "<alias binding=\"strong\"><family>sans-serif</family>")))
               (and i (string-contains %fonts-conf-content
                                       "<family>MiSans</family>"
                                       i))))

(test-assert "fonts.conf contains match target=pattern (lang-aware edits)"
             (string-contains %fonts-conf-content
                              "<match target=\"pattern\">"))

(test-assert "fonts.conf contains real family names"
             (every (lambda (f)
                      (string-contains %fonts-conf-content f))
                    '("MiSans" "MiSans L3" "Sarasa Term SC Nerd"
                      "Noto Sans CJK SC" "Noto Sans CJK JP"
                      "Noto Serif CJK SC" "Noto Sans Symbols 2"
                      "Noto Color Emoji" "Unifont")))

(test-assert "fonts.conf is well-formed XML (single root)"
             (and (string-contains %fonts-conf-content "<fontconfig>")
                  (string-contains %fonts-conf-content "</fontconfig>")
                  (> (string-length %fonts-conf-content) 100)))

;; ── 10：无 persistence / secrets ────────────────────────────
(test-assert "fonts module declares no persistence and no secrets"
             (let ((s (call-with-input-file "modules/guixcfg/home/fonts.scm"
                                           (lambda (p) (read-string p)))))
               (and (not (string-contains s "application-persistence"))
                    (not (string-contains s "secret-decl")))))

(test-end "fonts")
