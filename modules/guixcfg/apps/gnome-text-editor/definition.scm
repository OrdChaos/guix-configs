;;; gnome-text-editor application unit：GNOME 文本编辑器（GNOME
;;; core）。含未保存草稿持久化（第一个 bind 整个 application
;;; data 目录的 rule——见下方持久化边界审计）。
;;;
;;; 来源（pinned guix 086bc58f 审计）：gnome-text-editor 定义于
;;; (gnu packages gnome)；48.3，meson，GTK4 + libadwaita +
;;; gtksourceview + libspelling + enchant + editorconfig-core-c。
;;; 包自带 desktop entry（data/org.gnome.TextEditor.desktop.in.in
;;; 实测：org.gnome.TextEditor.desktop，Exec=gnome-text-editor
;;; %U；MimeType=text/plain;application/x-zerosize）。
;;;
;;; 草稿持久化（pinned 48.3 源码审计，src/editor-*.c）：
;;;   - 全部文件型状态位于 ~/.local/share/gnome-text-editor/
;;;     （g_get_user_data_dir() + APP_ID）：
;;;       * drafts/<uuid>        —— 未保存文档内容（草稿正文）；
;;;       * session.gvariant     —— 会话状态：drafts 映射
;;;         （draft-id→title/uri）、打开的 pages/windows、窗口
;;;         尺寸（editor-session.c:616）；
;;;       * recently-used.xbel   —— 最近文件书签；
;;;       * page-setup / print-settings —— 打印偏好。
;;;   - 恢复语义（editor-session.c restore 路径审计）：草稿的
;;;     【发现】依赖 session.gvariant 的 drafts 数组（restore_v1_
;;;     drafts → self->drafts → sidebar "Unsaved"）；只持久化
;;;     drafts/ 目录会在下次正常启动时被 restore_delete_unused
;;;     的 delete_unused_worker 当作无引用草稿【删除】（枚举
;;;     drafts 目录，删除不在已知 draft-id 集合内的文件）——
;;;     草稿正文与 drafts 映射是同目录同文件集的原子单元，不能
;;;     拆分。
;;;   - 因此持久化边界 = 整个 ~/.local/share/gnome-text-editor/
;;;     （application data 目录，bind-directory 粒度）：
;;;       * 目标满足：用户关闭/重启后，未保存草稿仍存在且可在
;;;         sidebar 恢复；
;;;       * recently-used.xbel 与 session.gvariant 中的窗口
;;;         尺寸随目录一并持久化——它们与 drafts 映射同处一个
;;;         应用自有目录，目录粒度下不可拆分（不做 single-file
;;;         bind：AGENT.md §12 非标准机制）；不新增 .cache 等
;;;         独立目录的持久化。
;;;   - GSettings（org.gnome.TextEditor 等）声明式管理明确不在
;;;     本任务范围（dconf 是 runtime derived state，由 apps/gtk
;;;     的既有机制处理外观键）；不声明 editor preferences。
;;;
;;; 桌面集成：.desktop 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。

(define-module (guixcfg apps gnome-text-editor definition)
               #:use-module (gnu packages gnome) ; gnome-text-editor
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%gnome-text-editor
                         %gnome-text-editor-desktop-entry))

;; GNOME Text Editor 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块
;; 引用，不在此决定默认应用。
(define %gnome-text-editor-desktop-entry "org.gnome.TextEditor.desktop")

(define %gnome-text-editor
  (application
   (name 'gnome-text-editor)
   (home-packages (list gnome-text-editor))
   (persistence
    (list (application-persistence-rule
           (name 'app-data)
           (backing "gnome-text-editor/app-data") ; backing root 相对（persistence.md）
           (consumer ".local/share/gnome-text-editor") ; HOME 相对（application data 目录）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
