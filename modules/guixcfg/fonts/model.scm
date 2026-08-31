;;; 字体包集合事实（single source；docs/reference/repository-layout.md）。
;;;
;;; %fonts：profile 安装哪些字体（"有哪些字体"）——中立事实，由
;;; Home profile（(guixcfg home fonts) 消费）、System profile
;;; （(guixcfg system packages) 的 Flatpak sandbox 字体投影）、
;;; apps 层 adapter（onlyoffice 的 bwrap 字体投影）共同消费。
;;; system 层不允许 import home 层（layering inversion），因此事实
;;; 放在这个中立域模块。
;;;
;;; fontconfig generic/fallback 策略是同域的独立文件：
;;; (guixcfg fonts fontconfig-policy)。

(define-module (guixcfg fonts model)
               #:use-module (gnu packages fonts)     ; font-google-noto-*
               #:use-module (gnu packages fontutils) ; fontconfig、font-gnu-unifont
               #:use-module (virelith packages fonts) ; mi-sans-global、maple-mono-*
               #:use-module (virelith packages fonts-windows) ; font-microsoft-win11-fod-hans
               #:export (%fonts))

;; 字体集合（profile 层：决定"有哪些字体"）。
;; 自有 channel：MiSans Global（简体主字体 + script 变体）、
;; Maple Mono Normal NL NF CN（等宽）；guix 官方：Noto 全 script、
;; CJK sans/serif、emoji、Symbols、Unifont last resort、fontconfig
;; （fc-* 工具 + 缓存再生）；Windows 简体中文补充字体
;; （DengXian/FangSong/KaiTi/SimHei，Microsoft payload）。
(define %fonts
  (list mi-sans-global
        maple-mono-default-nf-cn
        maple-mono-normal-nl-nf-cn
        font-google-noto
        font-google-noto-emoji
        font-google-noto-sans-cjk
        font-google-noto-serif-cjk
        font-gnu-unifont
        font-microsoft-win11-fod-hans
        fontconfig))
