;;; 统一 XDG / default-applications 策略（Guix Home owns）：用户级
;;; 默认应用选择——MIME associations、URL scheme handlers、默认
;;; 浏览器、默认 PDF/图片查看器等；以及 XDG user directories 声明。
;;; 应用模块只描述应用本身；“是否被选作默认”由本模块决定
;;; （AGENT.md §Application layer、docs/architecture/applications.md）。
;;;
;;; 机制：官方 home-xdg-mime-applications-service-type 声明式生成
;;; $XDG_CONFIG_HOME/mimeapps.list 的 [Default Applications]
;;; （derived state，随 Home generation 重建；不进 application
;;; persistence）。desktop entry 事实来自应用模块的纯数据常量
;;; （如 %chrome-desktop-entry）——本模块不复制应用专属字符串；
;;; 依赖方向 policy → app metadata，无循环。
;;;
;;; 变更默认应用只改本文件（增删 association / 换默认浏览器）。

(define-module (guixcfg home xdg)
               #:use-module (gnu home services xdg)  ; home-xdg-mime-applications-*、home-xdg-user-directories-service-type
               #:use-module (gnu services)           ; simple-service、service
               #:use-module (guixcfg apps google-chrome-stable definition)
               #:use-module (guixcfg apps amberol definition)
               #:use-module (guixcfg apps celluloid definition)
               #:use-module (guixcfg apps loupe definition)
               #:use-module (guixcfg apps gnome-text-editor definition)
               #:use-module (guixcfg flatpak applications wps) ; %wps-desktop-entry
               #:export (%xdg-default-applications
                         %xdg-default-apps-service
                         %xdg-user-dirs-service))

;; 默认浏览器：Google Chrome（stable）。desktop entry 来自 Chrome
;; 模块的纯数据常量；选择策略在这里——默认 HTML 与 http/https
;; scheme 都指向 Chrome。
(define %xdg-default-applications
  (map (lambda (mime)
         (cons mime (list %chrome-desktop-entry)))
       '("text/html"
         "application/xhtml+xml"
         "x-scheme-handler/http"
         "x-scheme-handler/https")))

;; ── GNOME 轻量应用默认关联（单一默认：每种 MIME 恰好一个
;;    default entry；其余候选经各自 desktop entry 的 MimeType
;;    出现在"Open With"）────────────────────────────────────
;; MIME 清单来自各包 desktop entry 声明的 MimeType 全集（pinned
;; 源码核实），音频额外补 canonical 类型（shared-mime-info 检测
;; 用 canonical 名，应用声明的是 x-* 别名——音频文件在文件管理
;; 器中必须能命中默认）。

;; 图片 → Loupe（包声明的完整 image/* 集，data/meson.build
;; mime_types 核实）。
(define %image-default-mime-types
  '("image/jpeg" "image/png" "image/gif" "image/webp" "image/tiff"
                 "image/x-tga" "image/vnd-ms.dds" "image/x-dds" "image/bmp"
                 "image/vnd.microsoft.icon" "image/vnd.radiance" "image/x-exr"
                 "image/x-portable-bitmap" "image/x-portable-graymap"
                 "image/x-portable-pixmap" "image/x-portable-anymap"
                 "image/x-qoi" "image/qoi" "image/svg+xml"
                 "image/svg+xml-compressed" "image/avif" "image/heic"
                 "image/jxl"))

;; 视频 → Celluloid（包声明的 video/* 集 + 流媒体 scheme
;; handler；x-scheme-handler 与既有 http/https 策略同构）。
(define %video-default-mime-types
  '("video/3gp" "video/3gpp" "video/3gpp2" "video/divx" "video/dv"
                "video/fli" "video/flv" "video/mp2t" "video/mp4" "video/mp4v-es"
                "video/mpeg" "video/mpeg-system" "video/msvideo" "video/ogg"
                "video/quicktime" "video/vnd.mpegurl" "video/vnd.rn-realvideo"
                "video/webm" "video/x-avi" "video/x-flc" "video/x-fli"
                "video/x-flv" "video/x-m4v" "video/x-matroska" "video/x-mpeg"
                "video/x-mpeg-system" "video/x-mpeg2" "video/x-ms-asf"
                "video/x-ms-wm" "video/x-ms-wmv" "video/x-ms-wmx"
                "video/x-msvideo" "video/x-nsv" "video/x-ogm+ogg"
                "video/x-theora" "video/x-theora+ogg"
                "x-scheme-handler/mms" "x-scheme-handler/mmsh"
                "x-scheme-handler/rtmp" "x-scheme-handler/rtp"
                "x-scheme-handler/rtsp"))

;; 音频 → Amberol（包声明的 audio/* 集 + canonical 补集
;; audio/flac|ogg|opus|aac|mp4|x-matroska——gstreamer 后端全部可播）。
(define %audio-default-mime-types
  '("audio/mpeg" "audio/wav" "audio/x-wav" "audio/x-aac"
                 "audio/aac" "audio/x-aiff" "audio/x-ape" "audio/x-flac"
                 "audio/flac" "audio/x-m4a" "audio/x-m4b" "audio/mp4"
                 "audio/x-mp1" "audio/x-mp2" "audio/x-mp3" "audio/x-mpg"
                 "audio/x-mpeg" "audio/x-mpegurl" "audio/x-opus+ogg"
                 "audio/opus" "audio/ogg" "audio/x-pn-aiff" "audio/x-pn-au"
                 "audio/x-pn-wav" "audio/x-speex" "audio/x-vorbis"
                 "audio/x-vorbis+ogg" "audio/x-wavpack" "audio/x-matroska"))

;; 文本 → GNOME Text Editor（包声明的 text/plain + 空文件类型）。
(define %text-default-mime-types
  '("text/plain" "application/x-zerosize"))

;; 办公文档 → WPS Office 365（Flatpak；desktop entry 名来自其
;; definition 的 %wps-desktop-entry——policy 不复制应用专属字符串）。
;; MIME 清单按办公文档域策划（2026-08）：WPS 365 的 Flathub
;; appstream 不含 mimetype 段（desktop 文件在 deb 包内，构建期才
;; 生成），无法像 ONLYOFFICE 那样取 AppStream 全集——本表取
;; OOXML 三件套全集（含宏启用与模板变体）+ 旧 MS 二进制格式 +
;; ODF text/spreadsheet/presentation（含模板）+ WPS 原生格式
;; （wps-office.*：wps/wpt 文档、et/ett 表格、dps/dpt 演示）+
;; rtf/csv/tsv/pdf，排除：
;;   - text/plain、text/markdown（文本编辑器领域；text/plain 已有
;;     GNOME Text Editor 默认，不制造重复 key）
;;   - Apple/Visio/StarOffice 旧格式、XPS、HWP、ODF flat-xml
;;     （WPS 不处理或过于边缘，留给 Open With）
;; 注：application/pdf 一并默认到 WPS（当前无独立 PDF 查看器；
;; 引入专用查看器后把该行移出本表即可）。
(define %office-default-mime-types
  '("application/msword"
    "application/msword-template"
    "application/pdf"
    "application/rtf"
    "application/vnd.ms-excel"
    "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
    "application/vnd.ms-excel.sheet.macroEnabled.12"
    "application/vnd.ms-excel.template.macroEnabled.12"
    "application/vnd.ms-powerpoint"
    "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
    "application/vnd.ms-powerpoint.slideshow.macroEnabled.12"
    "application/vnd.ms-powerpoint.template.macroEnabled.12"
    "application/vnd.ms-word.document.macroEnabled.12"
    "application/vnd.ms-word.template.macroEnabled.12"
    "application/vnd.oasis.opendocument.presentation"
    "application/vnd.oasis.opendocument.presentation-template"
    "application/vnd.oasis.opendocument.spreadsheet"
    "application/vnd.oasis.opendocument.spreadsheet-template"
    "application/vnd.oasis.opendocument.text"
    "application/vnd.oasis.opendocument.text-template"
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
    "application/vnd.openxmlformats-officedocument.presentationml.template"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
    "application/wps-office.dps"
    "application/wps-office.dpt"
    "application/wps-office.et"
    "application/wps-office.ett"
    "application/wps-office.wps"
    "application/wps-office.wpt"
    "text/csv"
    "text/tab-separated-values"))

(define (mime-defaults mime-types desktop-entry)
  "MIME-TYPES 全部指向 DESKTOP-ENTRY 的 default association 列表。"
  (map (lambda (mime) (cons mime (list desktop-entry)))
       mime-types))

(define %xdg-default-applications
  (append (mime-defaults %image-default-mime-types %loupe-desktop-entry)
          (mime-defaults %video-default-mime-types %celluloid-desktop-entry)
          (mime-defaults %audio-default-mime-types %amberol-desktop-entry)
          (mime-defaults %text-default-mime-types
                         %gnome-text-editor-desktop-entry)
          (mime-defaults %office-default-mime-types
                         %wps-desktop-entry)
          (map (lambda (mime)
                 (cons mime (list %chrome-desktop-entry)))
               '("text/html"
                 "application/xhtml+xml"
                 "x-scheme-handler/http"
                 "x-scheme-handler/https"))))

(define %xdg-default-apps-service
  (simple-service 'xdg-default-apps
                  home-xdg-mime-applications-service-type
                  (home-xdg-mime-applications-configuration
                   (default %xdg-default-applications))))

;; ── XDG user directories ──────────────────────────────────────
;; 官方 home-xdg-user-directories-service-type（pinned
;; gnu/home/services/xdg.scm）：生成 $XDG_CONFIG_HOME/user-dirs.dirs
;; （GTK 等经 xdg-user-dir 查询目录位置）+ activation 创建各目录
;; （$HOME/<Name>；user-dirs.conf enabled=False 防止 xdg-user-dirs-
;; update 改写）。default value 即标准 XDG 全集（Desktop/
;; Documents/Downloads/Music/Pictures/Projects/Public/Templates/
;; Videos）——显式声明意图，目录位置与持久化 backing 的对应由
;; (guixcfg system user-persistence) 的 %persistent-user-dirs 提供
;; （两处一致性由 tests/test-user-persistence.scm 回归）。
(define %xdg-user-dirs-service
  (service home-xdg-user-directories-service-type))
