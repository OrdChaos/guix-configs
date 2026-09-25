;;; mission-center application unit：系统资源监视器（GTK4 +
;;; libadwaita；CPU/内存/磁盘/网络/GPU 与进程/服务管理）。
;;;
;;; 来源（pinned virelith 087c78c 审计）：mission-center 以 Virelith 的
;;; 1.2.0 定义为基底，并应用一个上游崩溃修复，源码构建（Meson 驱动
;;; GUI 与 Magpie 两个 Cargo workspace，crate 离线 vendored）。Magpie
;;; 从 (virelith packages monitoring) 的 nvtop `source` output 编译，
;;; 不再构建期下载。pinned Guix 只有 libadwaita 1.8.x，包内自带
;;; (virelith packages libadwaita) 1.9.3（GTK4 gnome_50 绑定需要）。
;;;
;;; 状态边界：全部用户设置经 GSettings schema
;;; io.missioncenter.MissionCenter（窗口尺寸、选中页、列排序、刷新
;;; 间隔、单位制等）——由本仓库 generic GSettings/dconf 投影管理。
;;; 本定义只固定 first-time-running=false（见下）；其余键保持 schema
;;; 默认，如需固定偏好在此追加 gsettings-setting。源码审计无文件型
;;; 应用数据（GUI 不写 user_config_dir/user_data_dir），因此无
;;; persistence rule。
;;; Magpie 的硬件数据库 hw.db 是包内只读数据，wrapper 经
;;; MC_MAGPIE_HW_DB 指向 store 路径。
;;;
;;; 桌面集成：desktop entry 经 profile share/applications 进
;;; XDG_DATA_DIRS（launcher 自动发现）；Wayland 原生；portal 由
;;; niri 会话提供。GPU 计数依赖运行时的 Mesa/Vulkan loader 与驱动，
;;; wrapper 已带 LD_LIBRARY_PATH/LIBGL_DRIVERS_PATH。
;;;
;;; 明确不做：修改 virelith 包；首次运行 setup 脚本（包内已禁用：
;;; 上游在共享 /tmp 暂存脚本并经 pkexec 执行，Guix 下不安全且不适配
;;; FHS）；设默认应用；为无状态应用造 persistence rule。

(define-module (guixcfg apps mission-center definition)
               #:use-module (guix records)
               #:use-module (guix packages)           ; package、package-source、origin
               #:use-module (guix gexp)                ; local-file
               #:use-module (guixcfg apps model)          ; application
               #:use-module (guixcfg gsettings model)     ; gsettings-setting
               #:use-module ((virelith packages mission-center)
                             #:prefix virelith:)
               #:export (%mission-center
                         %mission-center-desktop-entry))

;; Mission Center 的 XDG desktop entry（包内 data/ 实际构建产物
;; share/applications/ 核实）。纯数据常量：供统一 XDG 策略模块引用，
;; 不在此决定默认应用。
(define %mission-center-desktop-entry "io.missioncenter.MissionCenter.desktop")

;; v1.2.0 receives a variable number of GPU metric series.  It only allocated
;; one Dataset initially, then indexed the additional readings and aborted.
;; Keep this small source fix local until the pinned channel includes it.
(define %mission-center-package
  (package
   (inherit virelith:mission-center)
   (source
    (origin
     (inherit (package-source virelith:mission-center))
     (patches
      (list (local-file "mission-center-dataset-count.patch"
                        "mission-center-dataset-count.patch")))))))

;; 静态偏好（io.missioncenter.MissionCenter，pinned 1.2.0 schema 实测）：
;;   first-time-running  bool  false
;; first-time-running 控制首次运行对话框（"Enabling Additional Values"，
;; src/window.rs 检测到 true 即 show_first_run_dialog()）。本仓库 dconf
;; 每次 boot 重建（dconf 有意不持久化），schema 默认 true 会让对话框在
;; 每次重启后首次打开都弹出；固定为 false 使其永不出现（setup 脚本本身
;; 已在 virelith 包内禁用）。其余键保持 schema 默认（窗口尺寸/选中页等
;; 由运行时写入 disposable dconf）。
(define %mission-center-gsettings
  (list (gsettings-setting
         (schema "io.missioncenter.MissionCenter")
         (key "first-time-running")
         (value "false"))))

(define %mission-center
  (application
   (name 'mission-center)
   ;; 单一包：GUI 与 Magpie 后端、desktop entry、GSettings schema 与
   ;; hw.db 均在其中；依赖经包闭包随 profile 进入（GTK4/libadwaita/
   ;; Mesa/Vulkan loader/nvtop 等）。
   (home-packages (list %mission-center-package))
   (gsettings %mission-center-gsettings)))
