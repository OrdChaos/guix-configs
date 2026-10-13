;;; musescore application unit：MuseScore Studio 音乐记谱/作曲软件。
;;;
;;; 来源（pinned guix 64e06748 审计）：musescore 定义于
;;; (gnu packages music)；4.6.5，qt-build-system（Qt 6 + QML），
;;; 启用系统 freetype/harfbuzz/tinyxml/opusenc/flac，播放后端
;;; alsa/portaudio/pulseaudio，MIDI 经 portmidi。Guix 包未设置
;;; MUSE_APP_INSTALL_SUFFIX，故安装产物为 mscore 可执行文件（含
;;; musescore symlink）与 org.musescore.MuseScore.desktop。
;;;
;;; 包自带 desktop entry（buildscripts/packaging/Linux+BSD/
;;; org.musescore.MuseScore.desktop.in 经 SetupAppImagePackaging.cmake
;;; 的 configure_file 实测：空 suffix 时落
;;; share/applications/org.musescore.MuseScore.desktop，
;;; Exec=mscore %U；MimeType 覆盖乐谱/记谱/MIDI/SoundFont 全集）。
;;;
;;; 角色边界（docs/architecture/applications.md）：
;;;   - 乐谱与 MIDI/SoundFont 文件关联的候选处理器；是否被选作
;;;     默认由统一 XDG 策略模块 (guixcfg home xdg) 决定，本模块只
;;;     导出 desktop entry 纯数据常量供策略层消费。
;;;   - 无 persistence rule：乐谱是用户文档（XDG user dirs），
;;;     应用偏好（~/.config/MuseScore）与最近文件属应用自有状态，
;;;     与 amberol/loupe 同类，不声明跨会话 persistence。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生（qtwayland）；
;;; portal 由 niri 会话提供。

(define-module (guixcfg apps musescore definition)
  #:use-module (gnu packages music) ;musescore
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%musescore %musescore-desktop-entry))

;; MuseScore 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %musescore-desktop-entry
  "org.musescore.MuseScore.desktop")

(define %musescore
  (application (name 'musescore)
               (home-packages (list musescore))))
