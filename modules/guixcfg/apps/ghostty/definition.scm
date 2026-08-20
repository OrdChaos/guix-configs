;;; ghostty application unit：terminal（niri bind Mod+T spawn ghostty）。
;;;
;;; 来源（pinned saayix c732c81 审计）：(saayix packages terminals) 的
;;; `ghostty`（稳定版 1.3.1，zig-build-system；`ghostty-latest` 是
;;; master 构建，不采用）。
;;;
;;; 配置：声明式（derived state，不持久化）——config.ghostty 经官方
;;; home-xdg-configuration-files-service-type 生成
;;; ~/.config/ghostty/config.ghostty（ghostty 官方读取路径），
;;; source-relative local-file colocate 本目录；字体族引用既有字体

(define-module (guixcfg apps ghostty definition)
               #:use-module (gnu home services)      ; home-xdg-configuration-files-service-type
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (saayix packages terminals) ; ghostty
               #:use-module (guixcfg apps model)
               #:export (%ghostty))

(define %ghostty
  (application
   (name 'ghostty)
   (home-packages (list ghostty))
   (home-services
    (list (simple-service 'ghostty-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("ghostty/config.ghostty"
                             ,(local-file "config.ghostty"
                                          "ghostty-config.ghostty"))))))))
