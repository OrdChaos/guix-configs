;;; Sunshine（Moonlight 串流主机，原生包；virelith (virelith packages
;;; sunshine)，实现参考 panther channel）。
;;;
;;; 采集：niri 的虚拟输出通过 wlr-screencopy 暴露；原生进程没有
;;; Flatpak 的 Wayland security context，因此 niri 不会隐藏
;;; zwlr_screencopy_manager_v1。虚拟输出不再由 niri 声明（不持久化）：
;;; apps.json 的 prep-cmd 调用 sunshine-start-virtual，按 Moonlight 请求的
;;; SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS 创建输出，scale 按 client width/1829
;;; 适配后设置 position/focus，undo 删除；Sunshine 正常退出/会话结束
;;; 会执行 undo，niri 退出（重启/关机）则输出随 compositor 消失。
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
;;; 凭据（方案 2：credentials_file / file_state 分离）：
;;;   - 登录凭据（username/salt/password hash）是 age 密文
;;;     secrets/credentials.json.age（ordinary domain），publisher 发布到
;;;     /run/guixcfg-secrets-ordinary/users/<user>/sunshine-credentials；
;;;   - sunshine.conf 的 `credentials_file` 指向该只读 runtime 文件，
;;;     `file_state` 保持默认 ~/.config/sunshine/sunshine_state.json，只
;;;     存配对状态（root.uniqueid/named_devices）；Web UI 改密码会失败
;;;     （设计如此，凭据归仓库）。
;;;
;;; apps.json 归仓库：`file_apps` 指向 home-files 只读投影
;;; ~/.local/share/sunshine/apps.json（仓库 apps.json），Web UI 的
;;; Applications 页保存会失败；app 列表只有虚拟输出串流一项。
;;;
;;; persistence：~/.config/sunshine 仍是 app-owned mutable state
;;; （sunshine_state.json 配对状态、credentials/、日志），seed-once 只写
;;; 首次 sunshine.conf；apps.json 不在持久化目录里。

(define-module (guixcfg apps sunshine definition)
  #:use-module (gnu home services) ;home-files-service-type
  #:use-module (gnu packages bash) ;bash（运行 prep shell 脚本）
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu services base) ;udev-rules-service
  #:use-module (guix gexp) ;file-append、local-file、plain-file、program-file
  #:use-module (guixcfg apps model)
  #:use-module (guixcfg security secrets) ;secret-decl、runtime-secret-target
  #:use-module (guixcfg system application-persistence)
  #:use-module (guixcfg users user) ;%primary-user
  #:use-module (virelith packages sunshine)
  #:export (%sunshine))

;;; Sunshine 的 password 是 util::hex(crypto::hash(password + salt))；
;;; util::hex 默认 rev=false 从摘要最后一字节开始输出，即**字节倒序**
;;; 的 SHA-256 digest，不是 sha256sum 的常规顺序。顺序写反会持续 401。

(define %sunshine-credentials
  (secret-decl (name 'sunshine-credentials)
               (scope 'user)
               (domain 'ordinary)
               (source (local-file "secrets/credentials.json.age"
                                   "sunshine-credentials.json.age"))
               (target-name "sunshine-credentials")
               (owner-user (user-profile-name %primary-user))
               (mode 256)))

(define %sunshine-credentials-target
  (runtime-secret-target %sunshine-credentials
                         (user-profile-name %primary-user)))

(define %sunshine-apps-file
  (local-file "apps.json" "sunshine-apps.json"))

(define %sunshine-start-virtual
  (program-file
   "sunshine-start-virtual"
   #~(execl #$(file-append bash "/bin/bash") "bash"
            #$(local-file "start-virtual-output.sh"
                          "sunshine-start-virtual.sh"))))

(define %sunshine-conf
  (plain-file
   "sunshine.conf"
   (string-append
    "capture = wlr\n"
    "output_name = virtual\n"
    "key_rightalt_to_key_win = enabled\n"
    "file_apps = "
    (user-profile-home-directory %primary-user)
    "/.local/share/sunshine/apps.json\n"
    "credentials_file = "
    %sunshine-credentials-target
    "\n")))

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
               (home-services (list (simple-service 'sunshine-managed-files
                                                    home-files-service-type
                                                    (list (list ".local/bin/sunshine"
                                                                %sunshine-launcher)
                                                          (list ".local/bin/sunshine-start-virtual"
                                                                %sunshine-start-virtual)
                                                          (list ".local/share/sunshine/apps.json"
                                                                %sunshine-apps-file)))))
               (system-services (list (udev-rules-service 'sunshine sunshine)
                                      (udev-rules-service
                                       'sunshine-libvirtualhid
                                       %sunshine-libvirtualhid-udev-rule)))
               (secrets (list %sunshine-credentials))
               (persistence (list (application-persistence-rule (name 'config)
                                                                (backing "sunshine/config")
                                                                (consumer ".config/sunshine")
                                                                (exposure 'bind-directory)
                                                                (lifecycle 'application-owned)
                                                                (seeds (list (list "sunshine.conf"
                                                                                   %sunshine-conf))))))))
