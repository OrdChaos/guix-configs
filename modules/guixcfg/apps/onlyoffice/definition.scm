;;; onlyoffice application unit：ONLYOFFICE Desktop Editors（virelith
;;; channel 提供的官方 Linux x64 二进制重打包）。
;;;
;;; 来源（pinned virelith d5697fa 审计）：onlyoffice-desktopeditors
;;; 定义于 (virelith packages onlyoffice)，9.4.0，binary-build-system
;;; （nonguix）。包层自带：
;;;   - bin/onlyoffice-desktopeditors（upstream launcher + 环境
;;;     wrapper：QT_QPA_PLATFORM=xcb、GStreamer 路径、PATH）；
;;;   - share/applications/onlyoffice-desktopeditors.desktop
;;;     （Exec 已指向 wrapper）；
;;;   - share/icons + bundled fonts/dictionaries（包层职责）。
;;; 不复制定义、不自建 wrapper、不处理 patchelf/RUNPATH/FHS
;;; （AGENT.md §7 Officialization——全部属 channel/package 层职责）。
;;;
;;; 配置与持久化边界（本任务决策）：
;;;   包层不生成任何只读 store symlink 到用户目录（virelith 包头
;;;   注释同款边界：persistence 与 MIME 默认编辑器接线留给配置层）；
;;;   mutable 配置由应用首次运行自建（DesktopEditors.conf、词典、
;;;   插件目录等全部 app-owned）。因此本模块无 home-files 贡献、
;;;   无 seeds（无 repo-owned 初始状态要预置）。
;;;   持久化（application persistence，bind-directory）：
;;;     ~/.config/onlyoffice/       —— 偏好（DesktopEditors.conf 等）；
;;;     ~/.local/share/onlyoffice/  —— 自定义词典、插件、
;;;        autosave/recovery（app-private 目录级 bind，不做文件白名单）。
;;;   不持久化 ~/.cache/onlyoffice/ —— 可重建 cache，随 ephemeral
;;;   HOME 消失（与 google-chrome-stable 的 ~/.cache 同姿态）。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；MIME default-editor 接线
;;; 不在本任务范围（后续与统一 XDG 策略模块协作，同 vscode）。

(define-module (guixcfg apps onlyoffice definition)
               #:use-module (virelith packages onlyoffice) ; onlyoffice-desktopeditors
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%onlyoffice
                         %onlyoffice-desktop-entry))

;; ONLYOFFICE 的 XDG desktop entry（virelith 包 install-plan 的
;; share/applications/ 目标核实）。纯数据常量：供统一 XDG 策略
;; 模块引用，不在此决定默认应用。
(define %onlyoffice-desktop-entry "onlyoffice-desktopeditors.desktop")

(define %onlyoffice
  (application
   (name 'onlyoffice)
   (home-packages (list onlyoffice-desktopeditors))
   (persistence
    (list (application-persistence-rule
           (name 'config)
           (backing "onlyoffice/config")          ; backing root 相对（persistence.md）
           (consumer ".config/onlyoffice")        ; HOME 相对（偏好 DesktopEditors.conf）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))
          (application-persistence-rule
           (name 'share)
           (backing "onlyoffice/share")           ; backing root 相对（persistence.md）
           (consumer ".local/share/onlyoffice")   ; HOME 相对（词典/插件/autosave）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
