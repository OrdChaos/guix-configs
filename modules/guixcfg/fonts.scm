;;; 共享字体包事实（single source；docs/reference/repository-layout.md）。
;;;
;;; 为什么从 (guixcfg home fonts) 上移到这里：
;;;   - %fonts 同时被 Home profile（用户字体集合）与 System profile
;;;     （Flatpak sandbox 字体投影）消费。pinned Guix 的 flatpak 包
;;;     （flatpak-fix-fonts-icons.patch）只把
;;;     /run/current-system/profile/share/fonts ro-bind 进 sandbox——
;;;     Home profile（~/.guix-home/profile/share/fonts）对 sandbox
;;;     不可见，因此同一份字体事实必须也能进 system profile；
;;;   - 不允许 system 层 import home 层（layering inversion），所以
;;;     事实放在这个中立模块，Home 与 System 各自 import 它；
;;;   - 不复制字体列表；模块只含包对象事实，不含任何 fontconfig
;;;     策略/服务（那些仍归 (guixcfg home fonts)）。
;;;
;;; 详见 docs/architecture/flatpak.md（fonts）。

(define-module (guixcfg fonts)
               #:use-module (gnu packages fonts)     ; font-google-noto-*
               #:use-module (gnu packages fontutils) ; fontconfig、font-gnu-unifont
               #:use-module (virelith packages fonts) ; mi-sans-global、maple-mono-*
               #:export (%fonts))

;; 字体集合（profile 层：决定"有哪些字体"）。
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
