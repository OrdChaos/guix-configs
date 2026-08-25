;;; celluloid application unit：GTK4 视频播放器（mpv 前端）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：celluloid 定义于
;;; (gnu packages video)；0.30，meson，GTK4 + libadwaita +
;;; libepoxy，经 libmpv client API 与 mpv 交互（不是命令行
;;; 包装）。包自带 desktop entry（data/
;;; io.github.celluloid_player.Celluloid.desktop.in 实测：
;;; io.github.celluloid_player.Celluloid.desktop，
;;; Exec=celluloid %U；MimeType 覆盖 video/* 全集 +
;;; x-scheme-handler/{mms,mmsh,rtmp,rtp,rtsp}）。
;;;
;;; 配置模型（保持独立）：
;;;   - mpv 是独立 application unit（apps/mpv：~/.config/mpv/
;;;     mpv.conf + input.conf 声明式 + watch-later 持久化）。
;;;     celluloid 经 libmpv 也会读用户 mpv.conf——但 mpv 配置
;;;     模型属于 mpv app，celluloid 不重复声明、不处理 mpv.conf
;;;     （后续单独设计）；
;;;   - 不新增 Celluloid 专用 persistence：无跨会话必须保留的
;;;     mutable state（播放进度恢复是 mpv watch-later 的职责，
;;;     属 mpv app 边界）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps celluloid definition)
               #:use-module (gnu packages video) ; celluloid
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%celluloid
                         %celluloid-desktop-entry))

;; Celluloid 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %celluloid-desktop-entry "io.github.celluloid_player.Celluloid.desktop")

(define %celluloid
  (application
   (name 'celluloid)
   (home-packages (list celluloid))))
