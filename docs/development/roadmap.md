# Roadmap

只记录尚未完成的事项、已知设计债与未来功能。已完成事项不保留在
roadmap（Git history 就是历史）。

## Known design debt / TODO

### stable identity offline-attack boundary

`secrets/bootstrap/stable-identity.age`（passphrase 加密私钥）位于
public repo，给攻击者离线尝试 master passphrase 的目标。长期选择：
public repo 只含 recipient + ciphertext、private identity 另存密码
管理器/离线备份；或维持现状但 master passphrase 必须高熵、独立于
登录密码（当前已独立）。不擅自迁移。

### configctl passwd / password rotation

未来 `configctl passwd` 语义：generate hash → update encrypted
provisioning source → atomically update installed persistent hash →
trigger/revalidate account projection → preserve fail-closed。不能长期
依赖运行期 `passwd user`（只改 ephemeral shadow，reboot 丢失）。

### 图形会话组件应用单元（niri spawn 引用，部分未入仓库）

niri common.kdl 的 spawn-at-startup / binds 引用以下二进制，对应
application 单元（registry 条目 + 包）尚未入仓库——包进入 session
PATH 前，无包机器（VM）上这些启动/按键会运行期失败（仅通知，不
影响配置合法性）：

- `clash-verge`（proxy GUI）
- binds 引用的 `missioncenter` / `playerctl` / `orca`
  （Guix 官方包名核对后入 registry）

（已入仓库：noctalia-git、polkit-gnome、nautilus、fcitx5、
xsettingsd。）

### 历史 E2E harness（保留、不维护）

`tools/test-tpm2-poc.sh`、`tools/test-tpm2-luks.sh`、
`tools/t7-scenario.sh`：历史 PoC/场景驱动，当前无调用者
（t7-scenario 已被 tests/integration/t3/run.sh 自带的 scenario
取代；test-tpm2-luks 的真实 cryptsetup 回退场景在 tests/ 无等价物）。
注意 `tools/t7-e2e.sh` 与 `tools/t7-interact.py` **不是** dead code：
tests/integration/t3 仍在用。若未来把 test-tpm2-luks 的场景移植为
Level 1-4 测试，这三个文件可删。

## Future features

- **configctl**（规划中，独立 Rust 部署工具，不解析 Scheme）：由
  personal-channel 打包安装为系统级工具；默认仓库 `~/guix-configs`
  （`GUIX_CONFIGS_REPO` 可覆盖，sudo 前解析绝对路径）；当前 host
  读 `/etc/guix-configs/host`（安装环境显式 `--host`）。命令：
  `check`、`system build/switch`、`home build/switch`、`channels
  show/refresh`、`disk inspect/plan/apply`、`install`。权限：普通
  用户负责编辑/Git/构建/检查，仅实际部署/磁盘/安装提权。**禁止**：
  自动 git pull、自动 clone 丢失仓库、自动更新 channel、自动部署脏
  工作区、后台监控、开机自动 reconfigure、自动删 Flatpak、自动选择
  可破坏磁盘。
- Laptop：完整 host 组装点 + 硬件驱动（kernel platform 已就位：
  `(guixcfg system kernel-platform)` 的 standard Linux +
  linux-firmware + Intel microcode 直接复用；实机 firmware 选择与
  microcode revision 验收属 laptop phase）。
- Mihomo / Flatpak 应用管理（docs 已规划，未实现）。

