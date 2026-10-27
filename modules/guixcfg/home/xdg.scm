;;; 统一 XDG / default-applications 策略（Guix Home owns）：用户级
;;; 默认应用选择——MIME associations、URL scheme handlers、默认
;;; 浏览器、默认 PDF/图片查看器等；以及 XDG user directories 声明。
;;; 应用模块只描述应用本身；“是否被选作默认”由本模块决定
;;; （AGENT.md §Application layer、docs/architecture/applications.md）。
;;;
;;; 机制：官方 home-xdg-mime-applications-service-type 声明式生成
;;; $XDG_CONFIG_HOME/mimeapps.list 的 [Default Applications] 与
;;; [Added Associations]（默认项同时显式关联，不依赖 MIME cache）
;;; （derived state，随 Home generation 重建；不进 application
;;; persistence）。desktop entry 事实来自应用模块的纯数据常量
;;; （如 %chrome-desktop-entry）——本模块不复制应用专属字符串；
;;; 依赖方向 policy → app metadata，无循环。
;;;
;;; 变更默认应用只改本文件（增删 association / 换默认浏览器）。

(define-module (guixcfg home xdg)
  #:use-module (gnu home services xdg) ;home-xdg-mime-applications-*、home-xdg-user-directories-service-type
  #:use-module (gnu services) ;simple-service、service
  #:use-module (guixcfg apps google-chrome-stable definition)
  #:use-module (guixcfg apps amberol definition)
  #:use-module (guixcfg apps celluloid definition)
  #:use-module (guixcfg apps loupe definition)
  #:use-module (guixcfg apps gnome-text-editor definition)
  #:use-module (guixcfg apps onlyoffice definition) ;%onlyoffice-desktop-entry
  #:use-module (guixcfg apps nautilus definition) ;%nautilus-desktop-entry
  #:use-module (guixcfg apps musescore definition) ;%musescore-desktop-entry
  #:use-module (guixcfg apps file-roller definition) ;%file-roller-desktop-entry
  #:use-module (guixcfg apps papers definition) ;%papers-desktop-entry
  #:use-module (guixcfg apps mpv definition)
  #:use-module (guixcfg apps prismlauncher definition)
  #:use-module (guixcfg apps seahorse definition)
  #:use-module (guixcfg apps vscode definition)
  #:use-module (guixcfg flatpak applications telegram definition)
  #:use-module (guixcfg flatpak applications discord definition)
  #:use-module (guixcfg flatpak applications steam definition)
  #:use-module (guixcfg flatpak applications tuba definition)
  #:use-module (guixcfg flatpak applications newsflash definition)
  #:use-module (guixcfg flatpak applications thunderbird definition)
  #:export (%xdg-default-applications %xdg-default-apps-service
                                      %xdg-user-dirs-service))

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
  '("image/jpeg" "image/png"
    "image/gif"
    "image/webp"
    "image/tiff"
    "image/x-tga"
    "image/vnd-ms.dds"
    "image/x-dds"
    "image/bmp"
    "image/vnd.microsoft.icon"
    "image/vnd.radiance"
    "image/x-exr"
    "image/x-portable-bitmap"
    "image/x-portable-graymap"
    "image/x-portable-pixmap"
    "image/x-portable-anymap"
    "image/x-qoi"
    "image/qoi"
    "image/svg+xml"
    "image/svg+xml-compressed"
    "image/avif"
    "image/heic"
    "image/jxl"
    ;; Loupe 50.0 的实际 desktop entry（旧清单未覆盖的类型）。
    "image/apng"
    "image/jp2"
    "image/x-win-bitmap"
    "image/x-xbitmap"
    "image/x-xpixmap"))

;; 视频 → Celluloid（包声明的 video/* 集 + 流媒体 scheme
;; handler；x-scheme-handler 与既有 http/https 策略同构）。
(define %video-default-mime-types
  '("video/3gp" "video/3gpp"
    "video/3gpp2"
    "video/divx"
    "video/dv"
    "video/fli"
    "video/flv"
    "video/mp2t"
    "video/mp4"
    "video/mp4v-es"
    "video/mpeg"
    "video/mpeg-system"
    "video/msvideo"
    "video/ogg"
    "video/quicktime"
    "video/vnd.mpegurl"
    "video/vnd.rn-realvideo"
    "video/webm"
    "video/x-avi"
    "video/x-flc"
    "video/x-fli"
    "video/x-flv"
    "video/x-m4v"
    "video/x-matroska"
    "video/x-mpeg"
    "video/x-mpeg-system"
    "video/x-mpeg2"
    "video/x-ms-asf"
    "video/x-ms-wm"
    "video/x-ms-wmv"
    "video/x-ms-wmx"
    "video/x-msvideo"
    "video/x-nsv"
    "video/x-ogm+ogg"
    "video/x-theora"
    "video/x-theora+ogg"
    ;; shared-mime-info canonical/alias pairs must select the same player.
    "video/vnd.avi"
    "video/avi"
    "video/vnd.divx"
    "video/x-flic"
    "video/x-ogm"
    "x-scheme-handler/mms"
    "x-scheme-handler/mmsh"
    "x-scheme-handler/rtmp"
    "x-scheme-handler/rtp"
    "x-scheme-handler/rtsp"))

;; 音频 → Amberol（包声明的 audio/* 集 + canonical 补集
;; audio/flac|ogg|opus|aac|mp4|x-matroska——gstreamer 后端全部可播）。
(define %audio-default-mime-types
  '("audio/mpeg" "audio/wav"
    "audio/x-wav"
    "audio/x-aac"
    "audio/aac"
    "audio/x-aiff"
    "audio/x-ape"
    "audio/x-flac"
    "audio/flac"
    "audio/x-m4a"
    "audio/x-m4b"
    "audio/mp4"
    "audio/x-mp1"
    "audio/x-mp2"
    "audio/x-mp3"
    "audio/x-mpg"
    "audio/x-mpeg"
    "audio/x-mpegurl"
    "audio/x-opus+ogg"
    "audio/opus"
    "audio/ogg"
    "audio/x-pn-aiff"
    "audio/x-pn-au"
    "audio/x-pn-wav"
    "audio/x-speex"
    "audio/x-vorbis"
    "audio/x-vorbis+ogg"
    "audio/x-wavpack"
    "audio/x-matroska"
    ;; Canonical/compatibility names of the already selected audio formats.
    "audio/m4a"
    "audio/mp2"
    "audio/mp3"
    "audio/mpegurl"
    "audio/m3u"
    "audio/vnd.wave"
    "audio/vorbis"))

;; 文本 → GNOME Text Editor（包声明的 text/plain + 空文件类型 +
;; Markdown——.md 用文本编辑器打开，而非 ONLYOFFICE）。
(define %text-default-mime-types
  '("text/plain" "application/x-zerosize" "text/markdown"))

;; 办公文档 → ONLYOFFICE Desktop Editors（原生 virelith 包 + bwrap
;; adapter；desktop entry 名来自其 definition 的
;; %onlyoffice-desktop-entry——policy 不复制应用专属字符串）。
;; MIME 清单 = 上游 desktop entry 声明的 MimeType 全集（virelith
;; 包安装的 share/applications/onlyoffice-desktopeditors.desktop
;; 实证），排除：
;;   - text/plain、text/markdown（文本编辑器领域；均有
;;     GNOME Text Editor 默认，不制造重复 key）
;;   - 电子书/图像类（epub、fictionbook、djvu——非 office 文档，
;;     在下方独立 ebook 组选择 ONLYOFFICE；DjVu 由 Papers 处理）
;;   - application/pdf（已由专用文档查看器 Papers 默认，见下方
;;     %document-default-mime-types）
;;   - x-scheme-handler/oo-office（下方单独声明 URL handler）
(define %office-default-mime-types
  '("application/msword" "application/msword-template"
    "application/oxps"
    "application/rtf"
    "application/vnd.apple.keynote"
    "application/vnd.apple.numbers"
    "application/vnd.apple.pages"
    "application/vnd.ms-excel"
    "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
    "application/vnd.ms-excel.sheet.macroEnabled.12"
    "application/vnd.ms-excel.template.macroEnabled.12"
    "application/vnd.ms-powerpoint"
    "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
    "application/vnd.ms-powerpoint.slideshow.macroEnabled.12"
    "application/vnd.ms-powerpoint.template.macroEnabled.12"
    "application/vnd.ms-visio.drawing.macroEnabled.main+xml"
    "application/vnd.ms-visio.drawing.main+xml"
    "application/vnd.ms-visio.stencil.macroEnabled.main+xml"
    "application/vnd.ms-visio.stencil.main+xml"
    "application/vnd.ms-visio.template.macroEnabled.main+xml"
    "application/vnd.ms-visio.template.main+xml"
    "application/vnd.ms-word.document.macroEnabled.12"
    "application/vnd.ms-word.template.macroEnabled.12"
    "application/vnd.ms-xpsdocument"
    "application/vnd.oasis.opendocument.graphics"
    "application/vnd.oasis.opendocument.presentation"
    "application/vnd.oasis.opendocument.presentation-flat-xml"
    "application/vnd.oasis.opendocument.presentation-template"
    "application/vnd.oasis.opendocument.spreadsheet"
    "application/vnd.oasis.opendocument.spreadsheet-flat-xml"
    "application/vnd.oasis.opendocument.spreadsheet-template"
    "application/vnd.oasis.opendocument.text"
    "application/vnd.oasis.opendocument.text-flat-xml"
    "application/vnd.oasis.opendocument.text-template"
    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
    "application/vnd.openxmlformats-officedocument.presentationml.template"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
    "application/vnd.sun.xml.calc"
    "application/vnd.sun.xml.impress"
    "application/vnd.sun.xml.writer"
    "application/vnd.sun.xml.writer.template"
    "application/wps-office.dps"
    "application/wps-office.dpt"
    "application/wps-office.et"
    "application/wps-office.ett"
    "application/wps-office.wps"
    "application/wps-office.wpt"
    "application/x-hwp"
    "text/csv"
    "text/tab-separated-values"))

;; ONLYOFFICE 9.4 desktop entry 声明 + 官方 SupportedFormats 文档确认
;; EPUB/FB2 可打开（导入时转换到 OOXML）；当前没有专用电子书应用。
(define %ebook-default-mime-types
  '("application/epub+zip" "application/x-fictionbook+xml"))

;; 乐谱/记谱/MIDI 文件 → MuseScore Studio（上游 desktop entry 声明的
;; MimeType 全集——空 MUSE_APP_INSTALL_SUFFIX 实测；唯一乐谱处理器，
;; 不制造重复 key）。x-scheme-handler/musescore 是 URL scheme handler，
;; 与既有 http/https、mms/rtsp 策略同构，一并默认到该 entry。
(define %score-default-mime-types
  '("application/x-musescore" "application/x-musescore+xml"
    "application/vnd.recordare.musicxml"
    "application/vnd.recordare.musicxml+xml"
    "application/x-mei+xml"
    "application/x-bww"
    "application/x-biab"
    "application/x-capella"
    "application/x-musedata"
    "application/x-overture"
    "application/x-tef"
    "application/x-sf2"
    "application/x-sf3"
    "audio/midi"
    "audio/x-gtp"
    "audio/x-ptb"
    "x-scheme-handler/musescore"))

;; 归档/压缩格式 → File Roller（GNOME Archive Manager）。MIME 清单 =
;; 上游 file-roller 3.42.0 data/supported-mime-types 全集（set-mime-
;; type-entry.py 经 meson 填入 desktop entry 的 @MIMETYPES@，pinned
;; 实测）；唯一归档管理器，不制造重复 key。含 .deb/.rpm/.apk/ISO/
;; 各类 tarball 压缩变体与 PE（application/x-ms-dos-executable，归档
;; 管理器以内容视图打开而非尝试执行）。
(define %archive-default-mime-types
  '("application/bzip2" "application/gzip"
    "application/vnd.android.package-archive"
    "application/vnd.ms-cab-compressed"
    "application/vnd.debian.binary-package"
    "application/x-7z-compressed"
    "application/x-7z-compressed-tar"
    "application/x-ace"
    "application/x-alz"
    "application/x-ar"
    "application/x-archive"
    "application/x-arj"
    "application/x-brotli"
    "application/x-bzip"
    "application/x-bzip-brotli-tar"
    "application/x-bzip-compressed-tar"
    "application/x-bzip1"
    "application/x-bzip1-compressed-tar"
    "application/x-cabinet"
    "application/x-cd-image"
    "application/x-chrome-extension"
    "application/x-compress"
    "application/x-compressed-tar"
    "application/x-cpio"
    "application/x-deb"
    "application/x-ear"
    "application/x-gtar"
    "application/x-gzip"
    "application/x-gzpostscript"
    "application/x-java-archive"
    "application/x-lha"
    "application/x-lhz"
    "application/x-lrzip"
    "application/x-lrzip-compressed-tar"
    "application/x-lz4"
    "application/x-lz4-compressed-tar"
    "application/x-lzip"
    "application/x-lzip-compressed-tar"
    "application/x-lzma"
    "application/x-lzma-compressed-tar"
    "application/x-lzop"
    "application/x-ms-dos-executable"
    "application/x-ms-wim"
    "application/x-rar"
    "application/x-rar-compressed"
    "application/x-rpm"
    "application/x-rzip"
    "application/x-rzip-compressed-tar"
    "application/x-source-rpm"
    "application/x-stuffit"
    "application/x-tar"
    "application/x-tarz"
    "application/x-tzo"
    "application/x-war"
    "application/x-xar"
    "application/x-xz"
    "application/x-xz-compressed-tar"
    "application/x-zip"
    "application/x-zip-compressed"
    "application/x-zoo"
    "application/x-zstd-compressed-tar"
    "application/zip"
    "application/zstd"
    ;; shared-mime-info 的规范名；旧 desktop entry 使用 x-* 别名。
    "application/vnd.rar"
    "application/x-bzip2-compressed-tar"))

;; 文档（PDF/DjVu/comic/illustrator）→ Papers（GNOME 专用文档查看器；
;; 上游 desktop entry 声明的 MimeType 全集——meson.build 的
;; papers_mime_types 实证）。PDF 家族（application/pdf 及 bz/gz/xz/ext
;; 别名）从此不再默认到 ONLYOFFICE（office 组已移除该行）。
;; 排除点：image/tiff 属图片域（Loupe 默认），不在此重复声明——
;; 跨组重复 key 会生成语义不确定的 mimeapps.list。
(define %document-default-mime-types
  '("application/pdf" "application/x-bzpdf"
    "application/x-ext-pdf"
    "application/x-gzpdf"
    "application/x-xzpdf"
    "application/illustrator"
    "application/x-ext-djv"
    "application/x-ext-djvu"
    "image/vnd.djvu"
    "image/vnd.djvu+multipage"
    "application/vnd.comicbook-rar"
    "application/vnd.comicbook+zip"
    "application/x-cb7"
    "application/x-cbr"
    "application/x-cbt"
    "application/x-cbz"
    "application/x-ext-cb7"
    "application/x-ext-cbr"
    "application/x-ext-cbt"
    "application/x-ext-cbz"))

;; Celluloid 0.30 desktop entry 的其余媒体类型：playlist/container、
;; 光盘和未被 Amberol/MuseScore 接管的音频。只取声明支持的类型；
;; 不假设 Amberol 的 GStreamer 后端一定装齐这些格式的插件。
(define %media-default-mime-types
  '("application/mpeg4-iod" "application/mpeg4-muxcodetable"
    "application/mxf"
    "application/ogg"
    "application/ram"
    "application/sdp"
    "application/streamingmedia"
    "application/vnd.apple.mpegurl"
    "application/vnd.ms-asf"
    "application/vnd.rn-realmedia"
    "application/vnd.rn-realmedia-vbr"
    "application/x-extension-m4a"
    "application/x-extension-mp4"
    "application/x-flac"
    "application/x-flash-video"
    "application/x-matroska"
    "application/x-ogg"
    "application/x-streamingmedia"
    "application/x-shorten"
    "audio/3gpp"
    "audio/3gpp2"
    "audio/ac3"
    "audio/AMR"
    "audio/amr-wb"
    "audio/basic"
    "audio/dv"
    "audio/eac3"
    "audio/mp1"
    "audio/mpg"
    "audio/scpls"
    "audio/vnd.dolby.heaac.1"
    "audio/vnd.dolby.heaac.2"
    "audio/vnd.dolby.mlp"
    "audio/vnd.dts"
    "audio/vnd.dts.hd"
    "audio/vnd.rn-realaudio"
    "audio/webm"
    "audio/x-gsm"
    "audio/x-it"
    "audio/x-mod"
    "audio/x-ms-asf"
    "audio/x-ms-wma"
    "audio/x-musepack"
    "audio/x-pn-realaudio"
    "audio/x-real-audio"
    "audio/x-realaudio"
    "audio/x-s3m"
    "audio/x-scpls"
    "audio/x-shorten"
    "audio/x-tta"
    "audio/x-xm"
    "x-content/audio-cdda"
    "x-content/audio-player"
    "x-content/video-dvd"))

;; mpv 0.41.0 声明但以上播放器清单未覆盖的格式/兼容别名。
;; shared-mime-info 中已有归属的同义类型必须留在同一组，不能仅按
;; MIME 字符串作差集（例如 audio/vnd.wave 与 audio/x-wav 等价）。
(define %mpv-default-mime-types
  '("application/smil" "application/x-smil"
    "application/x-cue"
    "application/x-mpegurl"
    "application/x-ogm"
    "application/x-ogm-audio"
    "application/x-ogm-video"
    "audio/aiff"
    "audio/mpeg2"
    "audio/mpeg3"
    "audio/musepack"
    "audio/rn-mpeg"
    "audio/x-adpcm"
    "audio/x-pls"
    "audio/x-pn-windows-pcm"
    "video/mkv"
    "video/x-mpeg3"
    "video/x-ms-afs"
    "video/x-ms-wvxvideo"))

;; Seahorse 47.0.1 desktop entry 全集；src/application.vala 的 open()
;; 调用 key_mgr.import_files，打开文件进入 GUI 导入流程。
(define %key-default-mime-types
  '("application/pgp-keys" "application/x-ssh-key"
    "application/pkcs12"
    "application/pkcs12+pem"
    "application/pkcs7-mime"
    "application/pkcs7-mime+pem"
    "application/pkcs8"
    "application/pkcs8+pem"
    "application/pkix-cert"
    "application/pkix-cert+pem"
    "application/pkix-crl"
    "application/pkix-crl+pem"
    "application/x-pem-file"
    "application/x-pem-key"
    "application/x-pkcs12"
    "application/x-pkcs7-certificates"
    "application/x-x509-ca-cert"
    "application/x-x509-user-cert"
    "application/pkcs10"
    "application/pkcs10+pem"
    "application/x-spkac"
    "application/x-spkac+base64"))

;; 当前 Flatpak export desktop entry 的 MimeType 全集。文件类型与
;; 登录/订阅回调协议均交给同一个 Thunderbird ESR 入口。
(define %mail-default-mime-types
  '("message/rfc822" "text/calendar"
    "text/vcard"
    "text/x-vcard"
    "x-scheme-handler/mailto"
    "x-scheme-handler/net.thunderbird"
    "x-scheme-handler/webcal"
    "x-scheme-handler/webcals"
    "x-scheme-handler/mid"))

(define (mime-defaults mime-types desktop-entry)
  "MIME-TYPES 全部指向 DESKTOP-ENTRY 的 default association 列表。"
  (map (lambda (mime)
         (cons mime
               (list desktop-entry))) mime-types))

(define %xdg-default-applications
  (append (mime-defaults %image-default-mime-types %loupe-desktop-entry)
          (mime-defaults %video-default-mime-types %celluloid-desktop-entry)
          (mime-defaults %audio-default-mime-types %amberol-desktop-entry)
          (mime-defaults %text-default-mime-types
                         %gnome-text-editor-desktop-entry)
          (mime-defaults %office-default-mime-types %onlyoffice-desktop-entry)
          (mime-defaults %score-default-mime-types %musescore-desktop-entry)
          (mime-defaults %archive-default-mime-types
                         %file-roller-desktop-entry)
          (mime-defaults %document-default-mime-types %papers-desktop-entry)
          (mime-defaults %ebook-default-mime-types %onlyoffice-desktop-entry)
          (mime-defaults %media-default-mime-types %celluloid-desktop-entry)
          (mime-defaults %mpv-default-mime-types %mpv-desktop-entry)
          (mime-defaults %key-default-mime-types %seahorse-desktop-entry)
          (mime-defaults %mail-default-mime-types %thunderbird-desktop-entry)
          (mime-defaults '("x-scheme-handler/tg" "x-scheme-handler/tonsite"
                           "x-scheme-handler/ton") %telegram-desktop-entry)
          (mime-defaults '("x-scheme-handler/discord") %discord-desktop-entry)
          (mime-defaults '("x-scheme-handler/steam"
                           "x-scheme-handler/steamlink") %steam-desktop-entry)
          (mime-defaults '("x-scheme-handler/tuba" "x-scheme-handler/web+ap")
                         %tuba-desktop-entry)
          (mime-defaults '("x-scheme-handler/newsflash"
                           "x-scheme-handler/feed") %newsflash-desktop-entry)
          (mime-defaults '("x-scheme-handler/curseforge"
                           "x-scheme-handler/prismlauncher"
                           "application/x-modrinth-modpack+zip")
                         %prismlauncher-desktop-entry)
          (mime-defaults '("x-scheme-handler/vscode")
                         %vscode-url-desktop-entry)
          (mime-defaults '("x-scheme-handler/oo-office")
                         %onlyoffice-desktop-entry)
          ;; 目录 → Nautilus（文件管理器）。必须显式声明：Amberol 的
          ;; desktop entry 也声明了 inode/directory（上游 MimeType
          ;; 异常）；无显式默认时 GIO 会把它解析为默认，"打开文件夹"
          ;; 因此启动 Amberol 而非 Nautilus（Prism Launcher 的
          ;; QDesktopServices::openUrl 同样受影响）。
          (mime-defaults '("inode/directory") %nautilus-desktop-entry)
          (map (lambda (mime)
                 (cons mime
                       (list %chrome-desktop-entry)))
               '("text/html" "application/xhtml+xml"
                 "application/xhtml_xml"
                 "application/xml"
                 "text/xml"
                 "application/rdf+xml"
                 "application/rss+xml"
                 "x-scheme-handler/http"
                 "x-scheme-handler/https"
                 "x-scheme-handler/google-chrome"))))

(define %xdg-default-apps-service
  (simple-service 'xdg-default-apps
                  home-xdg-mime-applications-service-type
                  ;; XDG MIME Applications spec: a default must also be
                  ;; associated. Explicit Added Associations lets GIO discover
                  ;; Flatpak handlers even without exports/mimeinfo.cache.
                  (home-xdg-mime-applications-configuration (default
                                                             %xdg-default-applications)
                                                            (added
                                                             %xdg-default-applications))))

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
