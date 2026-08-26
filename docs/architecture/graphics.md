# Graphics / Session Architecture

Wayland desktop 会话结构（M2）。capability owner 分层见
`upstream-boundaries.md`（officialization register）。

## 登录链（readiness 之后）

```
interactive-session-ready（core readiness join barrier）
     ├─ greetd（tty1；desktop.scm，extra-shepherd-requirement
     │    = interactive-session-ready；无 autologin）
     │      → default_session = agreety（greeter，运行在 greeter
     │        专用账号，HOME=/var/empty 是 greeter 的 home）
     │      → 用户在 agreety 提示符认证
     │      → IPC StartSession（cmd = 下方 user-session，env = '()）
     │      → greetd session worker（root）：PAM（unix-pam-service
     │        + pam_elogind）→ getpwnam(认证用户) →
     │        HOME/USER/LOGNAME/SHELL = passwd entry（greetd
     │        upstream 设置）→ /run/user/$UID（elogind）
     │        → execve(session, PAM envlist)——greeter 的
     │        HOME=/var/empty 不可能被继承（execve 整体替换环境）
     │        ——greetd 配置 source-profile? #f：worker 直接 exec
     │        wrapper，不预 source profiles（否则 ~/.profile 的
     │        on-first-login 先于 wrapper 运行，PAM 的
     │        XDG_SESSION_TYPE=tty 进入 Shepherd/会话 dbus → portal
     │        gnome 后端 settings-only；详见 desktop.scm 头注释）
     │      → greetd-user-session（官方 wrapper：只设置
     │        XDG_SESSION_TYPE / XDG_RUNTIME_DIR；bash -l）
     │      → ~/.bash_profile（Guix Home 生成）
     │           ├─ setup-environment（Home profile PATH）
     │           └─ on-first-login → Home Shepherd
     │                ├─ dbus（home-dbus-service-type）
     │                ├─ niri（home-niri-service-type；bash -l -c
     │                │    "exec niri --session"）
     │                ├─ pipewire + wireplumber
     │                │    （home-pipewire-service-type）
     │                └─ niri config spawn：polkit-gnome、fcitx5、
     │                     noctalia（兼 notification daemon）、
     │                     xsettingsd-session（X11 XSETTINGS）
     │
     │   注销语义：niri 由 Home Shepherd 监管（respawn 默认开），
     │   合成器退出 ≠ 会话结束——注销必须终止登录会话本身。
     │   noctalia 的 niri 注销经包 patch（apps/noctalia-git）改走
     │   loginctl terminate-session（elogind）：整个 login session
     │   收尾 → 回 agreety。
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
  环境，greeter 的 HOME=/var/empty 不可能继承（agreety 的 IPC 只传
  cmd + env='()）。**不是** pam_env（pam_env.so 无参数、只 honor
  /etc/environment——本机为空，无 HOME 规则）、**不是** Guix wrapper
  （只设置 XDG_SESSION_TYPE/XDG_RUNTIME_DIR）、**不是** custom
  硬编码（此前 HOME=/var/empty 事故根除）。契约测试：
  tests/test-desktop.scm H1-H5。
- **PATH**：Guix Home（bash_profile → setup-environment）提供。
- **user session D-Bus**：home-dbus-service-type 唯一 owner（不再有
  custom dbus-run-session）。
- **niri config**：`~/.config/niri/` 由 Home 声明式生成
  （home-xdg-configuration-files-service-type）——derived state，不
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

## NVIDIA adapter contract（当前 disabled/identity）

`modules/guixcfg/system/graphics/nvidia.scm` 是未来 proprietary
NVIDIA 的 seam（不启用、不填充）。未来 ownership：
selected %kernel → matching kernel module + firmware + KMS +
nouveau blacklist + nvda/replace-mesa + nvidia-prime/prime-run +
hybrid Intel+NVIDIA + Secure Boot module signing boundary。
桌面层无需改动（GPU-neutral）。
