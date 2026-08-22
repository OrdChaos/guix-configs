;;; 统一字体集合与 Fontconfig generic-family/fallback 策略（Guix
;;; Home owns）。
;;;
;;; 职责划分（任务架构）：
;;;   - %fonts：profile 安装哪些字体（“有哪些字体”）；
;;;   - home-fontconfig-service-type：generic family 映射与缺字
;;;     fallback（“如何回落”）；
;;;   应用层（GTK/Qt/browser/editor）配置不在本模块范围。
;;;
;;; 所有 family 名来自对实际 store 构建产物的 fc-scan 核实
;;; （2026-08，pinned guix 8a2afa6 / virelith cf5a6a0b / nonguix
;;; 7ae28dc）：
;;;   MiSans            lang zh-cn/zh-sg（简体主字体，无 ja/ko/zh-tw）
;;;   MiSans L3         lang 空（扩展平面汉字补充，须补 lang 才可选中）
;;;   Maple Mono Normal NL NF CN  lang zh-cn/zh-hk/zh-mo/zh-sg（monospace 主）
;;;   Noto Sans / Noto Serif / Noto Sans Mono /
;;;   Noto Sans Symbols / Noto Sans Symbols 2
;;;   Noto Color Emoji  lang und-zsye
;;;   Noto Sans CJK SC/TC/JP/KR、Noto Serif CJK SC/TC/JP/KR
;;;     实测所有 variant 的 lang 覆盖完全相同（ja/ko/zh-cn/zh-hk/
;;;     zh-mo/zh-sg/zh-tw）——原生 lang 无法区分 variant，必须显式
;;;     language-aware edits；
;;;   GNU Unifont → family 名 "Unifont"（last resort）。
;;;
;;; CJK 策略：
;;;   - 无 lang（默认）：显式列表顺序 SC → TC → JP → KR（sans/serif
;;;     相同；monospace 由 Maple Mono 先行），不依赖 locale 排序；
;;;   - lang=zh-cn/zh-sg：MiSans 优先（简体中文由 MiSans 处理，
;;;     §6.3）；
;;;   - lang=ja / zh-tw / zh-hk / zh-mo / ko：prepend 对应 variant
;;;     （JP/TC/KR，binding=strong）；
;;;   - MiSans L3 无 lang 元数据：target=font 补 CJK lang，使其在
;;;     扩展平面字符上可被 lang 感知选中（不取代 MiSans 主字体）；
;;;   - script（Arabic/Devanagari/Thai/...）不塞进全局候选列表，
;;;     走 fontconfig 原生 lang 匹配（MiSans Arabic 等独立 family）。
;;;
;;; 生成机制：官方 home-fontconfig-service-type（pinned guix 8a2afa6
;;; (gnu home services fontutils)）——value 是 snippet 列表：字符串
;;; → <dir>，list → 原样 SXML，输出
;;; $XDG_CONFIG_HOME/fontconfig/fonts.conf，activation 时 fc-cache。
;;; 不手写 XML 模板、无 shell 生成、无 activation hook。
;;;
;;; 注意（pinned guix 8a2afa6 审计）：home-environment 的
;;; home-environment-default-essential-services 已自带一个
;;; home-fontconfig 实例（default value '("~/.guix-home/profile/
;;; share/fonts")，即 profile 字体目录）。因此本模块用
;;; simple-service 扩展该 canonical 实例（只贡献 SXML 规则），
;;; 不创建第二个同型 service（否则 .config/fontconfig/fonts.conf
;;; 出现重复条目）。目录 snippet 由 essential 默认值提供。

(define-module (guixcfg home fonts)
               #:use-module (gnu home services fontutils) ; home-fontconfig-service-type
               #:use-module (gnu packages fonts)          ; font-google-noto-*
               #:use-module (gnu packages fontutils)      ; fontconfig
               #:use-module (gnu services)                ; service
               #:use-module (virelith packages fonts)     ; 自定义字体
               #:use-module (srfi srfi-1)                 ; append-map
               #:export (%fonts
                         %fontconfig-service))

;; ── 字体集合（profile 层：决定“有哪些字体”）─────────────────
;; 自有 channel：MiSans Global（简体主字体 + script 变体）、
;; Maple Mono Normal NL NF CN（等宽）；guix 官方：Noto 全 script、
;; CJK sans/serif、emoji、Symbols、Unifont last resort、fontconfig
;; （fc-* 工具 + 缓存再生）。
(define %fonts
  (list mi-sans-global
        maple-mono-default-nf-cn
        maple-mono-normal-nl-nf-cn
        font-google-noto
        font-google-noto-emoji
        font-google-noto-sans-cjk
        font-google-noto-serif-cjk
        font-gnu-unifont
        fontconfig))

;; ── Fontconfig snippet 构造 ─────────────────────────────────
;; generic family 主链（无 lang 时的默认顺序；SC 在 JP 前，§6.1）。
;; binding 属性按 fonts.dtd 只合法于 <alias> 元素与 <edit>（prefer
;; 的 <family> 不接受 binding——2.16.0 实机警告验证）；alias
;; binding=strong 锁定顺序不被系统 65-nonlatin 等规则重排。
(define %sans-serif-families
  ;; MiSans 主（简体优先）→ L3（扩展字符补充）→ Noto Sans → CJK
  ;; SC→TC→JP→KR → Symbols → Emoji → Unifont（last resort）
  '("MiSans" "MiSans L3" "Noto Sans"
             "Noto Sans CJK SC" "Noto Sans CJK TC" "Noto Sans CJK JP"
             "Noto Sans CJK KR"
             "Noto Sans Symbols" "Noto Sans Symbols 2"
             "Noto Color Emoji" "Unifont"))

(define %serif-families
  ;; Noto Serif → Noto Serif CJK SC→TC→JP→KR → Emoji → Unifont。
  ;; MiSans 是 sans，不进 serif 主链（§8）。
  '("Noto Serif"
    "Noto Serif CJK SC" "Noto Serif CJK TC" "Noto Serif CJK JP"
    "Noto Serif CJK KR"
    "Noto Color Emoji" "Unifont"))

(define %monospace-families
  ;; Maple Mono Normal NL NF CN 主 → Noto Sans Mono → CJK SC→TC→JP→KR
  ;; （§9；复杂 script 缺字时正确显示优先于等宽）
  '("Maple Mono Normal NL NF CN" "Noto Sans Mono"
                                 "Noto Sans CJK SC" "Noto Sans CJK TC" "Noto Sans CJK JP"
                                 "Noto Sans CJK KR"
                                 "Noto Sans Symbols" "Noto Sans Symbols 2"
                                 "Noto Color Emoji" "Unifont"))

(define (alias-sxml generic families)
  "SXML：generic family 的 alias 主链。"
  `(alias (@ (binding "strong"))
          (family ,generic)
          (prefer ,@(map (lambda (f) (list 'family f)) families))))

(define (family-lang-edit generic lang variant chain)
  "SXML：pattern 的 family=GENERIC 且 lang 包含 LANG 时，把整条
CHAIN 替换为 VARIANT 置首的版本（mode=assign_replace——实测
2.16.0 语义：prepend/assign 只作用于测试命中的值，alias 后 family
列表尾部的 generic 残留会让变体落不到首位；assign_replace 删除
全部 family 值后重建，变体稳定在首位）。"
  `(match (@ (target "pattern"))
          (test (@ (name "family") (compare "eq")) (string ,generic))
          (test (@ (name "lang") (compare "contains")) (string ,lang))
          (edit (@ (name "family") (mode "assign_replace") (binding "strong"))
                ,@(map (lambda (f) (list 'string f))
                       (cons variant (delete variant chain))))))

;; lang-aware CJK edits：所有 Noto CJK variant 的 lang 覆盖同构
;; （fc-scan 实测 ja/ko/zh-cn/zh-hk/zh-mo/zh-sg/zh-tw 全同），原生
;; lang 无法区分 variant——必须显式指定（§6.2）。zh-cn/zh-sg 不需要
;; edit（默认主链已 SC 优先且 MiSans 处理简体优先）。
(define %cjk-lang-edits
  (append-map
   (lambda (entry)
     (let ((lang (first entry))
           (sans (second entry))
           (serif (third entry))
           (mono (fourth entry)))
       (list (family-lang-edit "sans-serif" lang sans %sans-serif-families)
             (family-lang-edit "serif" lang serif %serif-families)
             (family-lang-edit "monospace" lang mono %monospace-families))))
   '(("ja" "Noto Sans CJK JP" "Noto Serif CJK JP" "Noto Sans CJK JP")
     ("zh-tw" "Noto Sans CJK TC" "Noto Serif CJK TC" "Noto Sans CJK TC")
     ("zh-hk" "Noto Sans CJK TC" "Noto Serif CJK TC" "Noto Sans CJK TC")
     ("zh-mo" "Noto Sans CJK TC" "Noto Serif CJK TC" "Noto Sans CJK TC")
     ("ko" "Noto Sans CJK KR" "Noto Serif CJK KR" "Noto Sans CJK KR"))))

;; script-aware edits（§7：script 变体经 language matching 使用，
;; 不塞进全局候选列表）。注：fontconfig 会把会话默认 lang（LANG/
;; LC_ALL）注入 pattern langset（fcdefault.c FcGetDefaultLangs），
;; MiSans 主字体覆盖 en/zh-cn 等，纯 lang 惩罚无法把 script 文本推给
;; script 变体——必须显式 assign_replace（与 CJK 同构）。
;; family 名与 lang 覆盖均来自 fc-scan 实测（MiSans Arabic=ar、
;; Thai=th、Tibetan=bo/dz、Myanmar=my、Khmer=km、Lao=lo、
;; Devanagari=hi/ne/mr/sa/...、Gujarati=gu、Gurmukhi=pa）。
;; serif ar 无 Noto Serif Arabic（font-google-noto 实测缺失）→
;; 用 Noto Sans Arabic（字形正确优先于衬线风格）。
(define %script-lang-edits
  (append-map
   (lambda (entry)
     (let ((lang (first entry))
           (sans (second entry))
           (serif (third entry))
           (mono (fourth entry)))
       (list (family-lang-edit "sans-serif" lang sans %sans-serif-families)
             (family-lang-edit "serif" lang serif %serif-families)
             (family-lang-edit "monospace" lang mono %monospace-families))))
   '(("ar" "MiSans Arabic" "Noto Sans Arabic" "Noto Sans Arabic")
     ("th" "MiSans Thai" "Noto Serif Thai" "Noto Sans Thai")
     ("bo" "MiSans Tibetan" "Noto Serif Tibetan" "Noto Sans Tibetan")
     ("my" "MiSans Myanmar" "Noto Serif Myanmar" "Noto Sans Myanmar")
     ("km" "MiSans Khmer" "Noto Serif Khmer" "Noto Sans Khmer")
     ("lo" "MiSans Lao" "Noto Serif Lao" "Noto Sans Lao")
     ("hi" "MiSans Devanagari" "Noto Serif Devanagari" "Noto Sans Devanagari")
     ("ne" "MiSans Devanagari" "Noto Serif Devanagari" "Noto Sans Devanagari")
     ("mr" "MiSans Devanagari" "Noto Serif Devanagari" "Noto Sans Devanagari")
     ("sa" "MiSans Devanagari" "Noto Serif Devanagari" "Noto Sans Devanagari")
     ("gu" "MiSans Gujarati" "Noto Serif Gujarati" "Noto Sans Gujarati")
     ("pa" "MiSans Gurmukhi" "Noto Serif Gurmukhi" "Noto Sans Gurmukhi"))))

;; MiSans L3：lang 元数据为空（fc-scan 实测），扩展平面字符在有 lang
;; 的 pattern 里会因 lang 惩罚永远输给 MiSans 主字体——target=font
;; 补齐 CJK lang，使其成为扩展汉字的合法 fallback（仍排在 MiSans
;; 之后，不取代主字体；BMP 字符由 MiSans 主字体优先）。
(define %mi-sans-l3-lang-edit
  ;; langset 子元素必须是 <string>（fcxml.c FcParseLangSet 只接受
  ;; FcVStackString；<lang> 是未知元素——2.16.0 实机警告验证）。
  '(match (@ (target "font"))
          (test (@ (name "family") (compare "eq")) (string "MiSans L3"))
          (edit (@ (name "lang") (mode "assign"))
                (langset (string "zh-cn") (string "zh-sg") (string "zh-tw")
                         (string "zh-hk") (string "zh-mo") (string "ja")
                         (string "ko")))))

;; generic family alias snippets（由 family 链数据生成）+ 固定别名
(define %generic-alias-snippets
  (append (list (alias-sxml "sans-serif" %sans-serif-families)
                (alias-sxml "serif" %serif-families)
                (alias-sxml "monospace" %monospace-families))
          ;; system-ui：与 sans-serif 一致的系统 UI 策略（§10）
          (list '(alias (@ (binding "strong"))
                        (family "system-ui")
                        (prefer (family "sans-serif"))))
          ;; emoji：显式别名（fc-match emoji 可用；§11）
          (list '(alias (@ (binding "strong"))
                        (family "emoji")
                        (prefer (family "Noto Color Emoji"))))))

;; 扩展 snippet 集合（不含目录——目录由 essential 默认值
;; '("~/.guix-home/profile/share/fonts") 提供）。
(define %fontconfig-snippets
  (append %generic-alias-snippets
          (list %mi-sans-l3-lang-edit)
          %cjk-lang-edits
          %script-lang-edits))

;; 经 native extension 贡献到 canonical home-fontconfig 实例
;; （essential services 已实例化；AGENT.md §15 同款模式）。
(define %fontconfig-service
  (simple-service 'guixcfg-fontconfig
                  home-fontconfig-service-type
                  %fontconfig-snippets))
