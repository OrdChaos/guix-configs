# Graphics / Session Architecture

Wayland desktop 会话结构（M2）。capability owner 分层见
`upstream-boundaries.md`（officialization register）。

## 登录链（readiness 之后）

```
interactive-session-ready（core readiness join barrier）
     ├─ greetd（tty1；desktop.scm，extra-shepherd-requirement
     │    = interactive-session-ready；无 autologin）
     │      → default_session = greetd-noctalia-session（virelith
     │        channel helper wrapper；greeter 专用账号，HOME=
     │        /var/empty 是 greeter 的 home）——helper 提供确定性
     │        PATH/XDG_DATA_DIRS 并以真实 noctalia-greeter-session
     │        的 store 路径为 argv0 exec（upstream 以 dirname "$0"
     │        相对定位自带 compositor/greeter，$0 语义保留）
     │      → noctalia-greeter-compositor（自带 wlroots，不套
     │        Sway/Cage）→ noctalia-greeter UI
     │      → 用户在 greeter UI 认证
     │      → IPC StartSession：cmd = 会话 .desktop 的 Exec
     │        （niri.desktop = <store>/bin/bash -l；repo-owned
     │        guixcfg-noctalia-greeter-sessions package 经 system
     │        profile 发布，greeter 经
     │        /run/current-system/sw/share/wayland-sessions 发现）
     │        env = XDG_SESSION_TYPE=wayland / XDG_CURRENT_DESKTOP
     │        / XDG_SESSION_DESKTOP（greeter sessionStartEnvironment）
     │      → greetd session worker（root）：PAM（unix-pam-service
     │        + pam_elogind）→ getpwnam(认证用户) →
     │        HOME/USER/LOGNAME/SHELL = passwd entry（greetd
     │        upstream 设置）→ /run/user/$UID（elogind）
     │        → execve(session, PAM envlist + IPC env)——greeter 的
     │        HOME=/var/empty 不可能被继承（execve 整体替换环境）
     │        ——IPC 的 XDG_SESSION_TYPE=wayland 在 pam.open_session
     │        之前进入 PAM env，pam_elogind（257.16 getenv_harder）
     │        读后按 wayland 注册会话——旧 agreety 时代的
     │        source-profile? #f + xdg wrapper 契约被 greeter
     │        原生接管（wrapper 已移除，source-profile? #f 保持；
     │        详见 desktop.scm 头注释）
     │      → bash -l
     │      → ~/.bash_profile（Guix Home 生成）
     │           ├─ setup-environment（Home profile PATH）
     │           └─ on-first-login → Home Shepherd
     │                ├─ dbus（home-dbus-service-type）
     │                ├─ niri（home-niri-service-type；wrapper
     │                │    "exec niri --session"）
     │                ├─ pipewire + wireplumber
     │                │    （home-pipewire-service-type）
     │                └─ niri config spawn：polkit-gnome、fcitx5、
     │                     noctalia（兼 notification daemon）、
     │                     xsettingsd-session（X11 XSETTINGS）
     │
     │   注销语义：niri 由 Home Shepherd 监管（respawn? #f），
     │   合成器退出 = 桌面会话结束。Noctalia 上游 Logout =
     │   niri IPC Quit（只退合成器；改 terminate-session 的 patch
     │   尝试已回退，2026-08-24）→ apps/niri 的 home-niri-session
     │   wrapper 检测 niri 退出后 loginctl terminate-session
     │   （elogind）：整个 login session 收尾 → 回 noctalia-greeter。
     │   Noctalia Greeter 集成职责（2026-08-28 迁移）：
     │     channel（(virelith services noctalia-greeter)）：
     │       polkit policy（apply-appearance）、package 进 system
     │       profile（Shell Sync 发现）、state dir owner/mode 0750
     │       greeter-owned、greeter 会话 PATH/XDG_DATA_DIRS。
     │     config repo（system/noctalia-greeter.scm）：
     │       machine-state persistence bind（sync.toml/壁纸跨
     │       boot）+ backing owner/mode、repo-owned 会话发现数据
     │       （niri.desktop）。
     │     Sync 链 = Noctalia Shell → pkexec apply-appearance →
     │     /var/lib/noctalia-greeter/。
     └─ mingetty（tty2-6，同样 gated by interactive-session-ready——
         desktop 故障时 fallback tty 仍可登录）
```

- **GPU-neutral**：desktop/session 层不知道任何具体 GPU vendor/driver。
  VM 的 virtio GPU 由 QEMU harness 暴露，guest 走 standard Linux 正常
  probe → Mesa → DRM render node。
- **HOME**：greetd 0.10.3 认证后在 session worker 里从认证用户的
  passwd entry 设置（`src/session/worker.rs`：getpwnam → putenv
  USER/LOGNAME/HOME/SHELL → getenvlist → fork+setuid →
  execve("/bin/sh","-c","exec <session>", envvec)）——execve 整体替换
  环境，greeter 的 HOME=/var/empty 不可能继承（noctalia-greeter 的
  IPC 只传 cmd + XDG_SESSION_TYPE/CURRENT_DESKTOP/SESSION_DESKTOP）。
  **不是** pam_env（pam_env.so 无参数、只 honor
  /etc/environment——本机为空，无 HOME 规则）、**不是** Guix wrapper
  （只设置 XDG_SESSION_TYPE/XDG_RUNTIME_DIR；已随 agreety 移除）、
  **不是** custom 硬编码（此前 HOME=/var/empty 事故根除）。契约
  测试：tests/test-desktop.scm G1-G3、H3-H5。
- **PATH**：用户会话由 Guix Home（bash_profile →
  setup-environment）提供；greeter 会话由 virelith channel 的
  greetd-noctalia-session helper 提供确定性 PATH（coreutils/dbus/
  elogind——session script 的 POSIX 工具、dbus 会话总线启动器与
  loginctl power actions）。
- **user session D-Bus**：home-dbus-service-type 唯一 owner（不再有
  custom dbus-run-session）。
- **niri config**：`~/.config/niri/` 由 Home 声明式生成
  （home-files-service-type，`.config/` 前缀）——derived state，不
  持久化、app 不是第二 authority。配置树（apps/niri/）：
  - `config.kdl`（app-owned，薄入口）：`include "common.kdl"` +
    `include "host.kdl" optional=true` + `include "noctalia.kdl"
    optional=true`（include 语义按 pinned niri 26.04 核实：相对路径
    基准 = 包含文件所在目录；optional 缺失仅警告——VM 无 host.kdl/
    noctalia.kdl 时配置仍合法）；
  - `common.kdl`（app-owned）：全部机器无关行为（input/layout/
    rules/animations/binds/cursor/spawn）；
  - `variants/laptop.kdl`（app-owned）：niri 声明的 'laptop
    configuration variant——机器事实（DRM 设备、固定输出），由
    generic selection resolver 安装为 `host.kdl`；host 层只做
    logical selection（(guixcfg apps selection)），不知道文件/路径；
    VM 无 selection（optional include 仅警告）；
  - `noctalia.kdl`：Noctalia 运行时生成（唯一 owner = Noctalia，
    Guix Home 不安装；entrypoint 只 include 不声明）。

## NVIDIA adapter contract（已实现，laptop 专属）

`modules/guixcfg/system/graphics/nvidia.scm` 是 proprietary NVIDIA
的唯一 seam：薄 wrapper 把本仓库 machine policy 映射为
`nonguix-transformation-nvidia` 的明确参数。ownership：

- kernel：**不选择、不替换**——transformation 对 OS 的 kernel/
  initrd/firmware 字段原样 inherit，`%kernel`
  （`(guixcfg system kernel-platform)`）仍是唯一权威；NVIDIA
  module 经 `linux-module-build-system` 的 `#:linux` 关键字自动
  针对 `%kernel` 构建；
- nouveau/nova 黑名单、`nvidia_drm.modeset=1`、nvidia-service-type
  （firmware/udev/nvidia-modprobe/linux-loadable-module/
  nvidia-prime/nvidia-powerd）、replace-mesa：全部由锁定版 Nonguix
  transformation 负责，本模块不重新实现；
- 参数（laptop = RTX 4050 Laptop，Ada）：`#:driver nvda-580`、
  `#:open-source-kernel-module? #t`（NVIDIA 自 R560 起推荐 Turing+
  使用 open module）、`#:kernel-mode-setting? #t`、
  `#:configure-xorg? #f`（纯 Wayland：greetd/niri，无 Xorg DM）、
  `#:dynamic-boost? #t`（Ampere 起支持，`nvidia-powerd`）；
- per-machine：只在 `(guixcfg hosts laptop)` 最终 `%os` 上调用；
  VM/Intel-only 机器不调用，零 NVIDIA closure（test-nvidia N6 +
  K8 固定）；
- Wayland：niri compositor 继续跑 Intel iGPU（`variants/laptop.kdl`
  的 `render-drm-device`），NVIDIA dGPU 仅 PRIME Render Offload
  （`prime-run`，由 nvidia-service-type 自动进 system profile）。
  无任何全局 NVIDIA/GBM 环境变量（禁止 `__GLX_VENDOR_LIBRARY_NAME`
  等 session-global 设置；它们只由 `prime-run` per-app 设置）；
- Secure Boot：当前 kernel 配置 `CONFIG_MODULE_SIG=n` 且无
  lockdown，out-of-tree module 无需签名。未来若启用
  `CONFIG_MODULE_SIG_FORCE`/lockdown，需在 Guix build phase 内
  重新设计 module signing pipeline（私钥不入 store、不改 store
  内 `.ko`）——见模块头 TODO，本阶段不实现。

桌面层无需改动（GPU-neutral）。
