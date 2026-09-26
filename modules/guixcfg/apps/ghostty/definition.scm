;;; ghostty application unit：terminal（niri bind Mod+T spawn ghostty）。
;;;
;;; 来源：(virelith packages ghostty) 的固定 1.3.1 release。其包定义
;;; 处理 upstream Zig dependency lock 与 Freedesktop Exec path 修复。
;;;
;;; 配置：声明式（derived state，不持久化）——config.ghostty 经
;;; home-files-service-type（".config/" 显式前缀）生成
;;; ~/.config/ghostty/config.ghostty（ghostty 官方读取路径），
;;; source-relative local-file colocate 本目录；字体族引用既有字体

(define-module (guixcfg apps ghostty definition)
               #:use-module (gnu home services)      ; home-files-service-type
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file
                #:use-module (virelith packages ghostty)
               #:use-module (guixcfg apps model)
               #:export (%ghostty))

(define %ghostty
  (application
   (name 'ghostty)
    (home-packages (list ghostty))
   (home-services
    (list (simple-service 'ghostty-config
                          home-files-service-type
                          `((".config/ghostty/config.ghostty"
                             ,(local-file "config.ghostty"
                                          "ghostty-config.ghostty"))))))))
