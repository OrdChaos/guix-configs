;;; fcitx5 application unit：输入法框架 + Rime（雾凇全拼 + 万象
;;; 语法模型 + FluentLight 主题）。
;;;
;;; 包来源（pinned 审计，2026-08）：
;;;   - Guix 官方 (gnu packages fcitx5)：fcitx5 5.1.21 / fcitx5-gtk /
;;;     fcitx5-qt。fcitx5 包自带 native-search-paths
;;;     FCITX_ADDON_DIRS 与 GUIX_GTK2/3_IM_MODULE_FILE——co-install
;;;     进同一 profile 即自动完成 addon 与 GTK immodule 接线，无需
;;;     手工环境变量；
;;;   - Virelith (virelith packages fcitx5 / rime)：fcitx5-rime-virelith
;;;     （闭包内含 librime-virelith（合并 lua+octagram 插件）与
;;;     rime-data-virelith（雾凇 schema/dict/lua/opencc；
;;;     RIME_DATA_DIR 编译期指向该 immutable shared data）、
;;;     fcitx5-fluentlight-theme（FluentLight / FluentLight-solid）、
;;;     rime-data-wanxiang（万象语法模型快照包——见文件头下段）。
;;;     不显式安装 librime-virelith/rime-ice/rime-data-virelith——
;;;     闭包已含。
;;;
;;; 万象 .gram 模型本体来自 Virelith 的 rime-data-wanxiang（快照
;;; 包）：上游 LTS 是滚动地址（内容原地更新、无固定历史版本 URL），
;;; fixed-output 的 sha256 会随时失效，因此 Virelith 以版本化
;;; snapshot release（RIME-LMDG.snapshot，tag = 快照时间戳，asset
;;; 按 tag immutable）pin 住模型——version 与快照 tag 同步升级，
;;; sha256 稳定。本单元经 file-append 把它作为 declarative
;;; occupant 落在 rime 用户目录（与仓库分发的配置文件同等级；
;;; Rime 资源解析 user dir 优先于 shared dir）。
;;;
;;; 生命周期：单一 owner = niri session（apps/niri/common.kdl 的
;;; spawn-at-startup "fcitx5" "-d"；会话内长期进程禁止第二 owner
;;; ——AGENT.md §7/§12）。本单元只负责让 fcitx5 进 session PATH；
;;; 无 Home Shepherd、无 system service、无 secrets。librime 的
;;; glog 版本问题属 Virelith 包层，本仓库不加 runtime workaround。
;;;
;;; 声明式配置 ownership（docs/architecture/persistence.md）：
;;;   - ~/.config/fcitx5/config、profile、conf/classicui.conf、
;;;     conf/rime.conf：repo-owned（home-files，.config 前缀）。
;;;     只声明相对默认值的刻意改动（Super+Space 切换键、
;;;     ShareInputState=No + rime InputState=All 组合、主题/字体/
;;;     分数缩放），行为基线是 Arch 实机验证过的习惯。
;;;     single-authority 立场：fcitx5 运行时修改 IM 列表/选项会
;;;     原子 rename 重写对应文件（替换 store symlink，当次会话内
;;;     漂移，下次 Home activation 自愈）——不安装独立 GUI 的
;;;     fcitx5-configtool 包，配置修改只走仓库；
;;;   - ~/.local/share/fcitx5/rime/*.custom.yaml：repo-owned
;;;     （home-files——非 .config 目标；Rime 只读 custom.yaml 从不
;;;     写入，无 dual-authority）。父目录保持真实目录，Rime 运行时
;;;     在旁边写 build/、user.yaml 等互不干扰；
;;;   - 不把频道 shared data（cn_dicts/lua/opencc 等版本化内容）
;;;     复制或 symlink 进 HOME——RIME_DATA_DIR 已由
;;;     fcitx5-rime-virelith 提供。唯一例外是万象 .gram：
;;;     频道单独打包为 rime-data-wanxiang（不进 RIME_DATA_DIR），
;;;     由本单元经 file-append 放进用户目录（见文件头上段）。
;;;
;;; 持久化边界（ephemeral HOME；docs/architecture/persistence.md
;;; 决策树 Preferred 2——mutable subdirectory）：
;;;   - persist：rime_ice.userdb/（唯一可写学习库。pinned
;;;     rime_ice.schema.yaml @ 80d213e 审计：主翻译器无显式
;;;     user_dict/db_class → 默认 leveldb 目录 rime_ice.userdb/；
;;;     melt_eng/radical_lookup 是 enable_user_dict: false；cn_en
;;;     与 custom_phrase 是只读 stabledb——均不产生可写用户库）；
;;;   - ephemeral：build/、installation.yaml、sync/、trash/
;;;     （rime-ice 自带预编译 build/，boot 后首次 deploy 以拷贝
;;;     校验为主，秒级）；
;;;   - user.yaml 有意 ephemeral：单文件，框架仅 directory bind
;;;     （AGENT.md §12：single-file bind 不是标准机制）；它只存
;;;     switch 选项记忆，默认值对本配置（全拼简体）正确——不为它
;;;     扩框架；
;;;   - 禁止持久化 ~/.config/fcitx5、~/.local/share/fcitx5、rime/
;;;     整体（forbidden consumer 规则；整目录 bind 还会遮蔽
;;;     declarative symlink）。
;;;
;;; 环境变量：XMODIFIERS=@im=fcitx（X11/XWayland 客户端经 XIM——
;;; fcitx 官方要求）+ QT_IM_MODULES=wayland;fcitx（Qt≥6.7 的
;;; fallback 列表：Wayland text-input 协议优先、fcitx immodule
;;; 兜底——Arch+niri 实机实证 noctalia/quickshell 需要 fallback
;;; 才能输入）。不设 GTK_IM_MODULE（GTK3/4 Wayland 走
;;; text-input-v3；X11 GTK 走 XIM + Guix immodule cache search
;;; path）；不设单值旧变量 QT_IM_MODULE。Chromium/Electron 的
;;; Wayland IME flags 属各应用单元，不进本单元。

(define-module (guixcfg apps fcitx5 definition)
               #:use-module (gnu home services)      ; home-files / xdg-config / env vars
               #:use-module (gnu packages fcitx5)    ; fcitx5、fcitx5-gtk、fcitx5-qt
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix records)
               #:use-module (virelith packages fcitx5) ; fcitx5-rime-virelith、fcitx5-fluentlight-theme
               #:use-module (virelith packages rime) ; rime-data-wanxiang
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%fcitx5))

(define %fcitx5
  (application
   (name 'fcitx5)
   (home-packages (list fcitx5 fcitx5-gtk fcitx5-qt
                        fcitx5-rime-virelith fcitx5-fluentlight-theme))
   (home-services
    (list ;; 声明式 Fcitx5 配置（~/.config/fcitx5/**）。
          (simple-service 'fcitx5-config
                          home-files-service-type
                          `((".config/fcitx5/config"
                             ,(local-file "config" "fcitx5-config"))
                            (".config/fcitx5/profile"
                             ,(local-file "profile" "fcitx5-profile"))
                            (".config/fcitx5/conf/classicui.conf"
                             ,(local-file "classicui.conf"
                                          "fcitx5-classicui.conf"))
                            (".config/fcitx5/conf/rime.conf"
                             ,(local-file "rime.conf"
                                          "fcitx5-rime-addon.conf"))))
          ;; 声明式 Rime 用户配置（~/.local/share/fcitx5/rime/——
          ;; 非 .config 目标，走 home-files；polkit-gnome 的
          ;; .local/bin wrapper 同款）。
          (simple-service 'fcitx5-rime-user-config
                          home-files-service-type
                          `((".local/share/fcitx5/rime/default.custom.yaml"
                             ,(local-file "default.custom.yaml"
                                          "fcitx5-rime-default-custom.yaml"))
                            (".local/share/fcitx5/rime/rime_ice.custom.yaml"
                             ,(local-file "rime_ice.custom.yaml"
                                          "fcitx5-rime-ice-custom.yaml"))
                            ;; 万象语法模型本体（Virelith 快照包
                            ;; rime-data-wanxiang，sha256 pinned；
                            ;; 见文件头）。
                            (".local/share/fcitx5/rime/wanxiang-lts-zh-hans.gram"
                             ,(file-append rime-data-wanxiang
                                           "/share/rime-data/wanxiang-lts-zh-hans.gram"))))
          ;; 会话环境（home-environment-variables 共享 sink 的
          ;; native extension——polkit-gnome PATH 同款模式）。
          (simple-service 'fcitx5-env
                          home-environment-variables-service-type
                          '(("XMODIFIERS" . "@im=fcitx")
                            ("QT_IM_MODULES" . "wayland;fcitx")))))
   (persistence
    (list (application-persistence-rule
           (name 'rime-userdb)
           (backing "fcitx5/rime_ice.userdb") ; backing root 相对（persistence.md）
           (consumer ".local/share/fcitx5/rime/rime_ice.userdb") ; HOME 相对
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
