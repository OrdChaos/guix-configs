# Graphics / Session Architecture

Wayland desktop 会话结构（M2）。capability owner 分层见
`upstream-boundaries.md`（officialization register）。

## 登录链（readiness 之后）

```
interactive-session-ready（core readiness join barrier）
     ├─ greetd（tty1；desktop.scm，extra-shepherd-requirement
     │    = interactive-session-ready；agreety greeter；无 autologin）
     │      → PAM（unix-pam-service + pam_elogind）
     │      → /run/user/$UID（elogind）+ HOME（pam_env，account 语义）
     │      → greetd-user-session（官方；bash -l；XDG wayland）
     │      → ~/.bash_profile（Guix Home 生成）
     │           ├─ setup-environment（Home profile PATH）
     │           └─ on-first-login → Home Shepherd
     │                ├─ dbus（home-dbus-service-type）
     │                ├─ niri（home-niri-service-type；bash -l -c
     │                │    "exec niri --session"）
     │                ├─ pipewire + wireplumber
     │                │    （home-pipewire-service-type）
     │                └─ niri config spawn：mako、lxpolkit
     └─ mingetty（tty2-6，同样 gated by interactive-session-ready——
         desktop 故障时 fallback tty 仍可登录）
```

- **GPU-neutral**：desktop/session 层不知道任何具体 GPU vendor/driver。
  VM 的 virtio GPU 由 QEMU harness 暴露，guest 走 standard Linux 正常
  probe → Mesa → DRM render node。
- **HOME**：来自 PAM（pam_env，从 account database）与 bash login
  语义——不是 custom wrapper 硬编码（此前 HOME=/var/empty 事故根除）。
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
