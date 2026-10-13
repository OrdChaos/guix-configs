;;; papers application unit：GNOME 文档查看器 Papers（GNOME core，
;;; Evince 的官方后继；PDF/DjVu/comic/TIFF 多格式阅读）。
;;;
;;; 来源（pinned guix 64e06748 审计）：papers 定义于
;;; (gnu packages gnome)；50.0，meson + cargo（Rust），GTK4 +
;;; libadwaita + libspelling，poppler（PDF）、djvulibre（DjVu）、
;;; libarchive（comic）、libtiff（TIFF）后端；nautilus 为其编译期
;;; 扩展 input。包自带 desktop entry（data/org.gnome.Papers.desktop.in.in
;;; 实测：org.gnome.Papers.desktop，Exec=papers %U；MimeType 由
;;; meson.build 的 papers_mime_types 生成——PDF/DjVu/comic/
;;; illustrator/TIFF 全集）。
;;;
;;; 角色边界（docs/architecture/applications.md）：
;;;   - 文档（PDF/DjVu/comic 等）文件关联的候选处理器；是否被选作
;;;     默认由统一 XDG 策略模块 (guixcfg home xdg) 决定，本模块只
;;;     导出 desktop entry 纯数据常量供策略层消费。
;;;   - 无 persistence rule：文档是用户数据（XDG user dirs），
;;;     应用偏好与最近文件属应用自有状态，与 amberol/loupe/
;;;     musescore 同类，不声明跨会话 persistence。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps papers definition)
  #:use-module (gnu packages gnome) ;papers
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%papers %papers-desktop-entry))

;; Papers 的 XDG desktop entry（上游 papers-50.0 源码
;; data/org.gnome.Papers.desktop.in.in 实测；本机未构建 store 产物）。
;; 纯数据常量：供统一 XDG 策略模块引用，不在此决定默认应用。
(define %papers-desktop-entry
  "org.gnome.Papers.desktop")

(define %papers
  (application (name 'papers)
               (home-packages (list papers))))
