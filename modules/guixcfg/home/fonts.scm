;;; 统一字体集合与 Fontconfig generic-family/fallback 策略（Guix
;;; Home owns）。
;;;
;;; 职责划分（任务架构）：
;;;   - %fonts：profile 安装哪些字体（“有哪些字体”）——shared fact，
;;;     现由中立模块 (guixcfg fonts) 拥有（System profile 的 Flatpak
;;;     sandbox 字体投影消费同一份事实，避免 system→home import；
;;;     docs/architecture/flatpak.md（fonts）），本模块 re-export
;;;     保持既有 Home API 不变；
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
;;;
;;; XDG 字体链接农场（~/.local/share/fonts/<pkg> → store
;;; share/fonts）：为环境被 CEF 白名单式清洗的渲染进程提供字体
;;; 目录。诊断链（2026-08 onlyoffice 字体缺失，全部实测）：
;;;   1. ONLYOFFICE 自身的 fontconfig 初始化会整目录加载所加载
;;;      fontconfig 包的 share/fontconfig/conf.avail；其中的
;;;      05-reset-dirs-sample.conf 含 <reset-dirs/>，把此前配置链
;;;      （store fonts.conf + conf.d + 用户配置）积累的全部字体目录
;;;      清空，只保留该 sample 重新声明的
;;;      <dir prefix="xdg">fonts</dir>（strace + 配置链模拟复现：
;;;      带该 pass 0 字体，不带 1589）。
;;;   2. CEF 的 zygote 对渲染进程环境做白名单式清洗（实测保留
;;;      HOME/LANG/PATH/DBUS_* 等；XDG_DATA_DIRS、FONTCONFIG_*、
;;;      LD_*、自定义变量全部剥除）——prefix="xdg" 的目录解析在
;;;      渲染进程里只剩 HOME fallback：~/.local/share/fonts（+
;;;      /usr/local/share、/usr/share 的 FHS 默认，Guix 无）。
;;;   3. 因此只有 ~/.local/share/fonts 下的字体能被渲染进程看到
;;;      （文档渲染 tofu、字体列表只剩 bundled 字体的直接原因）。
;;;      字体规则（alias/lang edit）不受 reset 影响——reset 只清
;;;      目录，本模块的 generic family 策略在渲染进程中依然生效
;;;      （fc-match sans-serif:lang=zh-cn → MiSans 实测）。
;;;
;;; 本服务为每个携带 share/fonts 的字体包在 ~/.local/share/fonts/
;;; 下建立指向 store 目录的链接（fontconfig 扫描时跟随子目录
;;; symlink——truetype/opentype 子目录链接实测生效；per-package
;;; 两层链接同构）。语义与 Home 其余资源一致：纯 store symlink、
;;; 随 Home generation 重建、不进 persistence、无 activation 复制。
;;;
;;; Maple 系排除：CEF 渲染进程的 fallback 字体匹配不含 alias
;;; 规则（其配置走 fontconfig 2.17 FcInitLoadOwnConfig 的
;;; FC_TEMPLATEDIR 扫描/内嵌 fallback，无用户配置的 generic
;;; 映射），bare match 按 family 名排序——"Maple Mono" 排在
;;; "MiSans"/"Noto" 之前，会把文档/UI 正文匹配抢成等宽 CJK +
;;; Nerd Font 字形（正文间隙过大、部分字形有误的直接原因；隐藏
;;; maple 链接后实测 match 落到 MiSans/Noto Sans CJK）。排除后
;;; 渲染进程的 bare match 首选 MiSans（sans）与 Noto CJK
;;; fallback。桌面的 monospace 策略不受影响（farm 只服务环境
;;; 清洗型渲染进程；正常链仍经 alias 显式匹配 Maple Mono）。
;;;
;;; 已知权衡：同一字体文件经两条路径可见（profile share 经
;;; XDG_DATA_DIRS + 本农场），fc-list 文件级列表出现双份条目；
;;; 按 family 聚合的选择器（GTK/Chromium/ONLYOFFICE）天然去重，
;;; 匹配语义不受影响。removal condition：上游不再整目录加载
;;; conf.avail / 停止 reset-dirs / CEF 停止清洗渲染进程环境。

(define-module (guixcfg home fonts)
               #:use-module (gnu home services fontutils) ; home-fontconfig-service-type
               #:use-module (gnu home services) ; home-files-service-type
               #:use-module (gnu services)      ; service、simple-service
               #:use-module (guix gexp)         ; file-append
               #:use-module (guix packages)     ; package-name
               #:use-module (guixcfg fonts)     ; %fonts、%home-fonts-xdg-link-exclusions（re-export）
               #:use-module (srfi srfi-1)       ; append-map、delete
               #:export (%fontconfig-service
                         %home-fonts-xdg-link-service)
               #:re-export (%fonts
                            %home-fonts-xdg-link-exclusions))

;; ── 字体集合（shared fact）─────────────────────────────────
;; %fonts / %home-fonts-xdg-link-exclusions 由 (guixcfg fonts) 提供
;; 并在此 re-export（single source；System 的 Flatpak 字体投影也
;; 消费同一份——docs/architecture/flatpak.md（fonts））。

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

;; ── XDG 字体链接农场（头部诊断链）──────────────────────────
;; 每个携带 share/fonts 的字体包 → ~/.local/share/fonts/<pkg-name>
;; 的目录链接（fontconfig 跟随子目录 symlink）。排除集来自共享
;; 事实 (guixcfg fonts) 的 %home-fonts-xdg-link-exclusions：
;; fontconfig（无字体目录）与 Maple 系（渲染进程 bare match 抢占
;; 正文，见头部）。
(define %home-fonts-xdg-link-service
  (simple-service 'home-fonts-xdg-links
                  home-files-service-type
                  (map (lambda (pkg)
                         (list (string-append ".local/share/fonts/"
                                              (package-name pkg))
                               (file-append pkg "/share/fonts")))
                       (filter (lambda (pkg)
                                 (not (member pkg
                                              %home-fonts-xdg-link-exclusions)))
                               %fonts))))
