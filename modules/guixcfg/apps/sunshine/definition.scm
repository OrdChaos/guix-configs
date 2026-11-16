;;; Sunshine（Moonlight 串流主机，原生包；virelith (virelith packages
;;; sunshine)，实现参考 panther channel）。
;;;
;;; 采集：niri 的虚拟输出通过 wlr-screencopy 暴露；原生进程没有
;;; Flatpak 的 Wayland security context，因此 niri 不会隐藏
;;; zwlr_screencopy_manager_v1。seed 把 capture 设为 wlr、
;;; output_name 设为 virtual（与 apps/niri 的全局虚拟输出同名）。
;;;
;;; 编码：构建关闭 CUDA/Vulkan（VAAPI 保留）；硬件编码走 NVENC 时
;;; FFmpeg 需要 dlopen libcuda.so.1——它只在系统 profile 的 lib 下，
;;; 不在 niri 会话的 loader 搜索路径。~/.local/bin/sunshine wrapper 在
;;; 保持现有 LD_LIBRARY_PATH 的前提下前置 /run/current-system/profile/lib
;;; （该目录不存在时无害，VM/Intel-only 机器只是回退到软件编码）。
;;;
;;; 输入：Sunshine 用 uinput/uhid；本 app 的系统贡献安装上游
;;; 60-sunshine.rules（GROUP="input" + TAG+="uaccess"，登录会话用户
;;; 经 logind ACL 获得访问权）。上游规则按旧名
;;; "Sunshine (libvirtualhid)*" 匹配，当前 libvirtualhid 生成的设备名是
;;; "libvirtualhid *"（Keyboard/Mouse/Mouse (Absolute)/Touchscreen/
;;; Pen Tablet），匹配不上 → niri/libinput 打不开 event 节点（只有
;;; root:input 0660），表现为只能看不能操作。因此额外安装一条按新名
;;; 匹配的 uaccess 规则；已有的 uinput 设备需要 udevadm trigger 或重启
;;; 才会拿到 ACL。
;;;
;;; persistence：~/.config/sunshine（sunshine.conf / apps.json /
;;; credentials / state）是 app-owned mutable state → 独立 backing，
;;; seed-once 只写首次初始配置。

(define-module (guixcfg apps sunshine definition)
  #:use-module (gnu home services) ;home-files-service-type
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu services base) ;udev-rules-service
  #:use-module (guix gexp) ;file-append、local-file、program-file
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg system application-persistence)
  #:use-module (virelith packages sunshine)
  #:export (%sunshine))

(define %sunshine-launcher
  (program-file
   "sunshine-launcher"
   #~(begin
       ;; FFmpeg dlopens libcuda.so.1 for NVENC; the proprietary driver's
       ;; userspace libraries live in the system profile, which is not on
       ;; the session loader path.  Prepend it; harmless when absent.
       (setenv "LD_LIBRARY_PATH"
               (string-append "/run/current-system/profile/lib:"
                              (or (getenv "LD_LIBRARY_PATH") "")))
       (apply execl #$(file-append sunshine "/bin/sunshine")
                "sunshine" (cdr (command-line))))))

(define %sunshine-libvirtualhid-udev-rule
  (file->udev-rule
   "61-sunshine-libvirtualhid.rules"
   (plain-file "61-sunshine-libvirtualhid.rules"
               (string-append
                "SUBSYSTEM==\"input\", ATTRS{name}==\"libvirtualhid *\", "
                "TAG+=\"uaccess\"\n"))))

(define %sunshine
  (application (name 'sunshine)
               (home-packages (list sunshine))
               (home-services (list (simple-service 'sunshine-launcher
                                                    home-files-service-type
                                                    (list (list ".local/bin/sunshine"
                                                                %sunshine-launcher)))))
               (system-services (list (udev-rules-service 'sunshine sunshine)
                                      (udev-rules-service
                                       'sunshine-libvirtualhid
                                       %sunshine-libvirtualhid-udev-rule)))
               (persistence (list (application-persistence-rule (name 'config)
                                                                (backing "sunshine/config")
                                                                (consumer ".config/sunshine")
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned)
                                                                (seeds (list (list "sunshine.conf"
                                                                                   (local-file "sunshine.conf"
                                                                                               "sunshine.conf"))
                                                                             (list "apps.json"
                                                                                   (local-file "apps.json"
                                                                                               "sunshine-apps.json")))))))))
