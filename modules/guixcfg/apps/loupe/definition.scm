;;; loupe application unit：GNOME 图片查看器（GNOME core）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：loupe 定义于
;;; (gnu packages gnome)；49.1，meson + cargo（Rust），GTK4 +
;;; libadwaita，glycin-loaders 解码沙箱（包内 wrap-program 注入
;;; XDG_DATA_DIRS 指向 glycin-loaders share）。包自带 desktop
;;; entry（data/org.gnome.Loupe.desktop.in.in 实测：
;;; org.gnome.Loupe.desktop，Exec=loupe %U；MimeType 全集经
;;; data/meson.build 的 mime_types 生成：jpeg/png/gif/webp/tiff/
;;; bmp/ico/avif/heic/jxl/svg/x-exr/qoi 等）。
;;;
;;; 无 persistence rule：图片查看无跨会话必须保留的 mutable
;;; state（收藏/最近文件属用户数据层关注，不进 application
;;; persistence）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps loupe definition)
               #:use-module (gnu packages gnome) ; loupe
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%loupe
                         %loupe-desktop-entry))

;; Loupe 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %loupe-desktop-entry "org.gnome.Loupe.desktop")

(define %loupe
  (application
   (name 'loupe)
   (home-packages (list loupe))))
