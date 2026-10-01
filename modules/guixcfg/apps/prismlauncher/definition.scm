;;; prismlauncher application unit: Prism Launcher（Minecraft 启动器）
;;; from the Virelith channel。
;;;
;;; 来源（pinned virelith f85e039 审计）：(virelith packages
;;; prismlauncher) 11.1.1——CMake 源码构建，递归拉取
;;; libraries/libnbtplusplus 子模块，内置 Java runtime downloader 在
;;; 包层以 -DLauncher_ENABLE_JAVA_DOWNLOADER=OFF 关闭。包层自带
;;; share/applications/org.prismlauncher.PrismLauncher.desktop、
;;; metainfo、图标与 man page，无需配置层补 desktop entry。
;;;
;;; Java：包声明了 PRISMLAUNCHER_JAVA_PATHS search path，profile 里
;;; apps/java 贡献的 JDK（(openjdk21 "jdk")）会被自动写入该变量，
;;; Prism 启动时据此发现 Java；本模块不重复声明 Java 依赖，也不使用
;;; Prism 自带的下载器。
;;;
;;; Persistence boundary（Prism 11.1.1 source/C 运行实证）：
;;;   ~/.local/share/PrismLauncher   launcher state。整个目录是单一
;;;     app-owned mutable unit：prismlauncher.cfg（[General] 偏好，
;;;     launcher 启动/退出时整文件重写）、accounts.json、
;;;     metacache/、icons/、themes/、translations/、logs/ 等。cfg 由
;;;     Prism 自己初始化与重写，故不作为 Home file 或 seed 从仓库
;;;     派生（应用自有状态，与 AAGL/VS Code 同类结论）。
;;;   ~/.config/PrismLauncher      不存在：Prism 的 XDG 路径全部落在
;;;     data dir（QStandardPaths::AppDataLocation 的父目录）。
;;;   ~/.cache/…                   不涉及。
;;;
;;; 游戏实例不进 app persistence：InstanceDir 是 prismlauncher.cfg
;;; [General] 的一条应用自有设置，用户在 GUI（Settings → Minecraft →
;;; Instance folder）手动指向 /persist/data-nobackup/prismlauncher
;;; （bulk、reacquirable、direct-access storage；路径 authority 是
;;; (guixcfg system gaming) 的 %prismlauncher-instances-path，目录由其
;;; activation 预先建好并归还 USER——/persist/data-nobackup 本身
;;; root-owned，USER 无法自建）。因此备份单元只含 launcher 状态，
;;; 不含数十 GB 游戏内容。仓库不 seed cfg（dual authority 非法）。

(define-module (guixcfg apps prismlauncher definition)
               #:use-module (virelith packages prismlauncher)
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg system application-persistence)
               #:export (%prismlauncher
                         %prismlauncher-desktop-entry))

;; Prism 的 XDG desktop entry 名（virelith 包 share/applications/ 实际
;; 构建产物核实）。纯数据常量：供统一 XDG 策略模块引用，本模块不决定
;; 默认应用（Prism 不是任何 MIME 的默认处理器）。
(define %prismlauncher-desktop-entry
  "org.prismlauncher.PrismLauncher.desktop")

(define %prismlauncher
  (application
   (name 'prismlauncher)
   (home-packages (list prismlauncher))
   (persistence
    (list (application-persistence-rule
           (name 'data)
           (backing "prismlauncher/data")
           (consumer ".local/share/PrismLauncher")
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
