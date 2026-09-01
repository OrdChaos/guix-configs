# Roadmap

只记录尚未完成的事项、已知设计债与未来功能。已完成事项不保留在
roadmap（Git history 就是历史）。

## Known design debt / TODO

### stable identity offline-attack boundary

`modules/guixcfg/security/secrets/age/stable-identity.age`
（passphrase 加密私钥）位于
public repo，给攻击者离线尝试 master passphrase 的目标。长期选择：
public repo 只含 recipient + ciphertext、private identity 另存密码
管理器/离线备份；或维持现状但 master passphrase 必须高熵、独立于
登录密码（当前已独立）。不擅自迁移。

### password rotation

未来密码轮换语义：generate hash → update encrypted provisioning
source → atomically update installed persistent hash →
trigger/revalidate account projection → preserve fail-closed。不能长期
依赖运行期 `passwd user`（只改 ephemeral shadow，reboot 丢失）。

### 图形会话组件应用单元（niri spawn 引用，部分未入仓库）

niri common.kdl 的 spawn-at-startup / binds 引用以下二进制，对应
application 单元（registry 条目 + 包）尚未入仓库——包进入 session
PATH 前，无包机器（VM）上这些启动/按键会运行期失败（仅通知，不
影响配置合法性）：

- ~~`clash-verge`（proxy GUI）~~ → 已由 Mihomo 系统服务取代
  （`(guixcfg system mihomo service)`，docs/architecture/mihomo.md；GUI 控制
  经 Noctalia Mihomo Control 走 Clash API）
- binds 引用的 `missioncenter` / `playerctl` / `orca`
  （Guix 官方包名核对后入 registry）

（已入仓库：noctalia、polkit-gnome、nautilus、fcitx5、
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

- **Immutable committed snapshot execution（部署 Level 2）**：Phase 1
  只保证 clean committed worktree gate（deployment starts only from a
  clean committed worktree）；真正从固定 commit 快照（git archive /
  detached worktree）执行部署并记录 deployed commit 是后续工作。
- Laptop：host 组装点已落地（`(guixcfg hosts laptop)` 完整 OS +
  NVIDIA open module adapter + niri iGPU/offload 机器事实）；剩余：
  实机 firmware 选择、microcode revision 验收、实机运行验证清单
  （prime-run/vulkaninfo/nvidia-smi/powerd，见 graphics.md）。
- Mihomo 系统服务与 Flatpak 应用管理已落地（mihomo.md /
  flatpak.md）；剩余是运维面打磨，不再作为未实现条目追踪。


### SmartDNS（Phase 2 v1 已落地 ownership；剩余见 dns.md）

- 已做：静态 /etc/resolv.conf → SmartDNS → 固定 upstream；DHCP DNS
  metadata（/run/resolvconf/resolv.conf）由 openresolv 产出、v1 不消费；
  resolvconf-bootstrap 退役。
- 未来：DHCP DNS 作为 SmartDNS 附加 upstream 组（hook 产出 + config
  再生成 + SIGHUP）；cache 持久化（如需要）。
