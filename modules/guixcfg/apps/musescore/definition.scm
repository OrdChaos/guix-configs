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
;;;   - 乐谱本身是用户文档：MuseScore 的 userDataPath() 是
;;;     QStandardPaths::DocumentsLocation + "/MuseScore4"
;;;     （~/Documents/MuseScore4），属 XDG user dirs，已由
;;;     (guixcfg system user-persistence) 持久化——本模块不重复声明。
;;;
;;; 持久化边界（pinned 4.6.5 源码审计；docs/architecture/
;;; persistence.md 决策树 Preferred 1——app-private namespace）：
;;;   - QSettings（IniFormat，org/app = MuseScore/MuseScore4）→
;;;     ~/.config/MuseScore/MuseScore4.ini：偏好、最近文件、
;;;     窗口尺寸/位置（man 页 FILES 节实证 MuseScore3.ini 同构）；
;;;   - userAppDataPath() = QStandardPaths::AppLocalDataLocation =
;;;     ~/.local/share/MuseScore/MuseScore4：extensions/plugins/
;;;     soundfonts/styles/templates、workspaces、locale、shortcuts.xml、
;;;     midimappings、known_audio_plugins.json、synthesiser settings、
;;;     musescore.com 凭据与 session、更新时间戳（各 *configuration.cpp
;;;     实证 appDataPath 拼接）；
;;;   - app-owned mutable state，非 repo-declarative（仓库不声明任何
;;;     MuseScore 配置文件）——两条 rule 各自 bind 整个 app-private
;;;     目录，无 mixed container、无 dual authority；
;;;   - 不持久化 ~/.cache/MuseScore（cache ephemeral）；
;;;   - ~/Documents/MuseScore4（用户乐谱）归 user dirs（见上）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；portal 由 niri 会话提供。
;;; Wayland：Guix 包 QT_PLUGIN_PATH 已含 qtwayland（native platform
;;; 插件齐备），但 MuseScore 4.6.5 main.cpp 在 Linux 上**默认强制
;;; QT_QPA_PLATFORM=xcb**（"Forced X11, with Wayland there are a
;;; number of problems now"；仅当环境变量 MU_QT_QPA_PLATFORM 非空
;;; 时才不强制——上游 AppImage 文档以 MU_QT_QPA_PLATFORM=wayland
;;; 启用）。因此默认经 XWayland 运行；本模块不代为启用 Wayland
;;; （如需启用，是会话环境层的显式选择，见模块头研究结论）。

(define-module (guixcfg apps musescore definition)
  #:use-module (gnu packages music) ;musescore
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system application-persistence) ;rule
  #:export (%musescore %musescore-desktop-entry))

;; MuseScore 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %musescore-desktop-entry
  "org.musescore.MuseScore.desktop")

(define %musescore
  (application (name 'musescore)
               (home-packages (list musescore))
               (persistence (list (application-persistence-rule (name 'config)
                                                                (backing
                                                                 "musescore/config") ;backing root 相对
                                                                (consumer
                                                                 ".config/MuseScore") ;MuseScore4.ini
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned))
                                  (application-persistence-rule (name 'share)
                                                                (backing
                                                                 "musescore/share") ;扩展/音色库/工作区/凭据/shortcuts
                                                                (consumer
                                                                 ".local/share/MuseScore")
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned))))))
