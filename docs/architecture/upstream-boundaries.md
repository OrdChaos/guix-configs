# Upstream Boundaries（officialization register）

capability 的 authoritative owner 一览。新问题先查这里：*Who owns this
capability?*——不要再造第二套实现。

判断原则（AGENT.md §6-7）：pinned official API 存在且语义基本完整 →
OFFICIAL；项目 invariant 需要 → THIN ADAPTER / KEEP（custom）。

## Register

| Capability | Authoritative implementation | Upstream primitive | Local adapter | Reason |
|---|---|---|---|---|
| Niri user lifecycle | Guix Home official | `home-niri-service-type`（bash -l -c "exec niri --session"；requirement home-dbus；profile 贡献 dbus/niri/xdg-desktop-portal-*/xwayland-satellite） | — | 官方完整覆盖 |
| User session D-Bus | Guix Home official | `home-dbus-service-type`（shepherd `dbus`，dbus-daemon --session） | — | 官方完整覆盖；不再有 custom dbus-run-session |
| PipeWire/WirePlumber | Guix Home official | `home-pipewire-service-type`（pipewire + wireplumber shepherd services + profile + alsa config） | — | 官方完整覆盖；niri 不再 spawn |
| Greetd login | Guix official + virelith service | `greetd-service-type` + virelith `noctalia-greeter-service-type` / `greetd-noctalia-session`（greeter 会话 PATH/XDG_DATA_DIRS、polkit、state dir owner/mode 由 channel service 提供） | `desktop.scm`：`extra-shepherd-requirement '(interactive-session-ready)` + tty1 + allow-empty-passwords? #f；greeter 机器策略（machine-state persistence + niri.desktop 会话数据）在 `system/noctalia-greeter.scm` | 官方服务；本地只加 readiness gate 与机器策略 |
| Login readiness barrier | guixcfg custom | —（官方 shepherd dependency 不是同语义） | `readiness.scm`（persistent-state/account-state/interactive-secrets/home/session-infra/interactive-session-ready + PAM gate） | 项目 capability 模型 |
| Fallback tty | Guix official | mingetty（tty2-6，gated by interactive-session-ready） | vm.scm（tty1 移除 + gating） | 官方服务 + 本地 gating |
| Account DB projection | guixcfg custom（KEEP） | 官方 account activation 有历史 runtime 问题 | `accounts.scm`（single-writer passwd/group/shadow + persistent verifier） | persistent root-only hash → ephemeral /etc/shadow 投影；hash 不进 store |
| Secrets publisher | guixcfg custom（KEEP） | — | `secrets.scm`（root-owned age publisher、/run/guixcfg-secrets generation publication） | stateless boot/readiness 语义 |
| SSH daemon | Guix official | `openssh-service-type` | — | 官方完整 |
| SSH persistent host-key | guixcfg adapter | — | `ssh.scm`（persistent host-key activation） | stateless-root host identity 语义 |
| User persistence | guixcfg custom（KEEP） | 官方 file-system primitive 在底层 | `user-persistence.scm`（canonical /persist backing + bind mounts） | which state persists / lifecycle / ownership 是项目语义 |
| Root generation lifecycle | guixcfg custom（KEEP） | — | `storage/root-generation.scm` + initrd + `boot/uki*.scm` | Normal（current + fresh @root）/ Recovery（previous confirmed pair） |
| TPM PCR7 unlock | guixcfg custom（KEEP） | — | `boot/tpm-unlock.scm` + initrd + tpm2-tools | PCR7-only policy；initrd 组合 |
| UKI / Secure Boot / Limine | guixcfg custom（KEEP） | — | `boot/uki.scm`/`uki-bootloader.scm`/`limine-menu.scm` | A/B deployment、签名、Normal/Recovery 菜单 |
| Custom initrd | guixcfg custom（KEEP） | raw-initrd 骨架（`gnu system linux-initrd`） | `boot/initrd.scm`（ephemeral-root-initrd + microcode composition） | LUKS/TPM/root-generation 选择需在 pre-mount 顺序中 |
| Kernel platform | guixcfg adapter（KEEP） | Nonguix `linux-7.2`/`linux-firmware`/`microcode-initrd` | `system/kernel-platform.scm` | exact pinned kernel + firmware + Intel microcode |
| Nonguix substitute trust | guixcfg removed（2026-08-25） | — | — | 第三方 substitute（substitutes.nonguix.org）已移除；nonguix 包本地编译（回归：tests/test-substitutes.scm T-S1..T-S6） |
| atomic-file helper | guixcfg custom（KEEP） | Guix 官方 helper 无 parent-dir fsync | `utils/atomic-file.scm` | crash-durable 语义（fsync file + parent） |
| Home pivot cleanup | guixcfg shim（NARROW） | 上游 symlink-manager 无 stale pivot 处理（pinned 实测） | `home/pivot.scm`（保守判定 + unlink） | removal condition：上游修复后删 |
| NVIDIA proprietary | guixcfg adapter（disabled） | — | `system/graphics/nvidia.scm` | 未来 seam；kernel module/KMS/blacklist/PRIME/nvda/Secure Boot signing 边界 |
| Graphical session services（polkit-gnome/fcitx5 等） | niri config spawn | — | `modules/guixcfg/apps/niri/config.kdl` | graphical-only lifecycle（polkit agent libexec 不在 PATH：apps/polkit-gnome 经 ~/.local/bin wrapper 暴露后恢复使用）；notification daemon 由 Noctalia 持有（mako 已移除） |

## HOME/PATH/D-Bus 语义（§7 根除 HOME=/var/empty）

- HOME 由 **greetd upstream** 设置（exact pinned audit 2026-08-18）：
  认证后在 session worker 里 `User::from_name(pam_username)`
  （getpwnam）→ putenv USER/LOGNAME/HOME/SHELL（passwd entry 的
  name/dir/shell）→ pam.open_session → getenvlist →
  execve("/bin/sh","-c","exec <session>", envvec)——execve 整体替换
  环境，greeter 的 HOME=/var/empty 不可能继承（greetd 0.10.3
  `src/session/worker.rs:162-216,239-276`；noctalia-greeter 的 IPC
  只传 cmd + XDG_SESSION_TYPE/CURRENT_DESKTOP/SESSION_DESKTOP，
  `greetd_client.cpp requestStartSession`）。**不是** pam_env
  （unix-pam-service 的 pam_env.so 无参数、只 honor
  /etc/environment——无 HOME 规则）、**不是** Guix wrapper（官方
  greetd-xdg-user-session-command 只设置 XDG_SESSION_TYPE /
  XDG_RUNTIME_DIR，`gnu/services/base.scm:3715-3729`——已随 agreety
  移除，XDG env 由 greeter 原生提供）、**不是** custom wrapper
  硬编码。契约测试：tests/test-desktop.scm G1-G3、H3-H5。
- 认证后的用户会话由 **greeter 经 greetd IPC** 启动：cmd = 会话
  .desktop 的 Exec（repo-owned niri.desktop = bash -l，经 system
  profile 的 wayland-sessions 被发现）+ sessionStartEnvironment。
  default-session-command = virelith channel 的
  `greetd-noctalia-session` helper（确定性 env + argv0 保留语义；
  非裸 upstream script）。不可把裸用户会话命令放在
  default-session-command（greetd 会把它当 greeter 以 greeter 用户
  无认证运行——server.rs greet()→start_greeter）。
- PATH：用户会话由 **Guix Home**（~/.bash_profile →
  setup-environment）提供 Home profile + system profile 命名空间；
  greeter 会话由 channel helper 提供确定性 PATH（coreutils/dbus/
  elogind）。
- user session D-Bus 由 **home-dbus-service-type** 提供（唯一 owner）。
- niri 由 **home-niri-service-type**（Home Shepherd）启动。

## KEEP 的原因（避免重复审计）

- **accounts**：官方 activation 的 FFI flock 在 boot 环境失败历史 +
  persistent root-only verifier 投影语义（hash 不进 store）。
- **readiness**：官方 shepherd dependency 不表达
  login-critical capability join（PAM gate + barrier 是项目语义）。
- **secrets**：root-owned age publisher 与 boot/reconfigure generation
  publication 是 stateless boot 语义；官方 Home secret manager 不是
  同模型。
- **root-generation/initrd/TPM/UKI/Secure Boot**：Normal/Recovery pair
  + PCR7 + A/B UKI 部署是项目架构，官方无对应。
- **atomic-file**：官方 helper 无 parent-dir fsync（断电语义不足）。
- **spawn helper**：static Guile / fork / GC 已验证问题，官方无等价
  修复证据。
