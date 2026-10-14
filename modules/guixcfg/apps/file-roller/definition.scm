;;; file-roller application unit：GNOME 归档/压缩包管理器（Archive
;;; Manager）。
;;;
;;; 来源（pinned guix 64e06748 审计）：file-roller 定义于
;;; (gnu packages gnome)；3.42.0，meson-build-system（glib-or-gtk），
;;; GTK3 + libhandy + libarchive，可选 nautilus 扩展未启用（Guix 包
;;; TODO: Add libnautilus）。包自带 desktop entry：上游
;;; data/meson.build 以 set-mime-type-entry.py 把
;;; data/supported-mime-types 填入 @MIMETYPES@，输出
;;; org.gnome.FileRoller.desktop（i18n.merge_file，install_dir
;;; share/applications）；Exec=file-roller %U，Icon=
;;; org.gnome.ArchiveManager，Categories 含 Archiving/Compression。
;;;
;;; 角色边界（docs/architecture/applications.md）：
;;;   - 归档/压缩格式的候选处理器；是否被选作默认由统一 XDG 策略
;;;     模块 (guixcfg home xdg) 决定，本模块只导出 desktop entry
;;;     纯数据常量供策略层消费。
;;;   - 无 persistence rule（与 nautilus/loupe 同类）：偏好走
;;;     GSettings（org.gnome.FileRoller，dconf 有意不持久化，见
;;;     (guixcfg gsettings) 与 apps/gtk）；最近文件走 GTK recent
;;;     （用户数据层）；唯一的文件型状态是
;;;     ~/.config/file-roller/options/（dlg-add.c 逐文件夹"添加到
;;;     归档"对话框选项的 GKeyFile，价值低），不声明跨会话
;;;     persistence。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；GTK3 Wayland 原生（X11 经
;;; xwayland-satellite）；portal 由 niri 会话提供。

(define-module (guixcfg apps file-roller definition)
  #:use-module (gnu packages gnome) ;file-roller
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%file-roller %file-roller-desktop-entry))

;; File Roller 的 XDG desktop entry（上游 3.42.0 data/meson.build
;; install_dir share/applications + i18n.merge_file 输出名实证）。
;; 纯数据常量：供统一 XDG 策略模块引用，不在此决定默认应用。
(define %file-roller-desktop-entry
  "org.gnome.FileRoller.desktop")

(define %file-roller
  (application (name 'file-roller)
               (home-packages (list file-roller))))
