;;; Mark Shot application unit（virelith channel 固定版本 package +
;;; 本仓库配置 seed）。
;;;
;;; 包来源：virelith channel 的 (virelith packages mark-shot) `mark-shot`
;;; ——上游 tag v0.1.58 的源码构建；Qt6 截图/标注/OCR/录制工具。version/
;;; commit/hash/依赖/运行时包装全部由 channel package 层固定（含
;;; layer-shell、原生 onnxruntime OCR provider 与 PP-OCRv5 模型 bundle、
;;; libav/PipeWire 录制），本仓库只消费 `mark-shot`，不 pin upstream、
;;; 不复制 definition。
;;;
;;; 配置模型（seed-once，docs/architecture/persistence.md（seed-once））：
;;;   config.json 从本仓库分发：首次 activation 时作为 seed 写入
;;;   backing 侧（/persist/data-app/mark-shot/config/config.json，经
;;;   .config/mark-shot 目录 bind 投影），此后 repo 永久放弃 ownership，
;;;   由 mark-shot/用户在应用内修改并跨 boot 保留。这满足「配置从
;;;   仓库分发」同时保留应用自身写回配置的能力（store symlink 只读的
;;;   做法会破坏应用保存设置）。
;;;
;;; 持久化边界：
;;;   ~/.config/mark-shot/      config.json 等偏好（seed + app-owned）；
;;;   ~/.local/share/mark-shot/ 截图历史、旧模型缓存等 app-private state
;;;                             （目录级 bind，无文件白名单）；
;;;   不持久化 ~/.cache/mark-shot。
;;;
;;; niri 集成：截图相关键位全部由 apps/niri 的 common.kdl 指向
;;; `mark-shot`（替换 niri 内置 screenshot action）；覆盖层走
;;; LayerShellQt，无需 window-rule。OCR 模型目录经 package wrapper 的
;;; MARK_SHOT_OCR_MODEL_DIR 注入，会话环境无需额外变量。

(define-module (guixcfg apps mark-shot definition)
  #:use-module (virelith packages mark-shot) ;mark-shot
  #:use-module (guix gexp) ;local-file
  #:use-module (guix records)
  #:use-module (guixcfg apps model) ;application
  #:use-module (guixcfg system application-persistence) ;application-persistence-rule
  #:export (%mark-shot))

(define %mark-shot
  (application (name 'mark-shot)
               (home-packages (list mark-shot)) ;用户 profile 包
               (persistence (list (application-persistence-rule (name 'config)
                                                                (backing
                                                                 "mark-shot/config") ;persistence root 下相对路径
                                                                (consumer
                                                                 ".config/mark-shot") ;HOME 相对
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned)
                                                                ;; seed-once：仓库分发初始 config.json；此后 repo 永不触碰。
                                                                (seeds `(("config.json" ,
                                                                          (local-file
                                                                           "config.json"
                                                                           "mark-shot-config.json")))))
                                  ;; 截图历史等 app-private state（跨 boot 保留）。
                                  (application-persistence-rule (name 'share)
                                                                (backing
                                                                 "mark-shot/share") ;persistence root 下相对路径
                                                                (consumer
                                                                 ".local/share/mark-shot") ;HOME 相对
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned))))))
