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
     │                └─ niri config spawn：mako、polkit-gnome
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
- **niri config**：`~/.config/niri/config.kdl` 由 Home 声明式生成
  （home-xdg-configuration-files-service-type）——derived state，不
  持久化、app 不是第二 authority。

## NVIDIA adapter contract（当前 disabled/identity）

`modules/guixcfg/system/graphics/nvidia.scm` 是未来 proprietary
NVIDIA 的 seam（不启用、不填充）。未来 ownership：
selected %kernel → matching kernel module + firmware + KMS +
nouveau blacklist + nvda/replace-mesa + nvidia-prime/prime-run +
hybrid Intel+NVIDIA + Secure Boot module signing boundary。
桌面层无需改动（GPU-neutral）。
