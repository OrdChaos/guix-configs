# Roadmap

只记录尚未完成的事项、已知设计债与未来功能。已完成事项不保留在
roadmap（Git history 就是历史）。

## Core phase gate

当前 Core phase 结束条件：

- consistency audit passes（本基线审计）
- docs restructure complete
- full tests pass
- system build passes
- fresh VM installation passes
- fresh boot/login passes

满足后才正式进入 Desktop / Laptop / Application persistence。

## Known design debt / TODO

### root Last Good readiness boundary

`ephemeral-root-confirm` 在 user-processes 后标记 boot ok / promote
Last Good，可能先于真正 interactive readiness（no usable login 但
root 被标 Last Good）。未来应与正确的 interactive readiness/health
语义对齐（对齐 login/session 就绪信号后再 promote）。

### login-critical vs ordinary secrets

`interactive-secrets-ready` 当前由全部 secrets（含 test/普通应用
secret）共同 provision——普通非关键 secret 失败会阻塞 interactive
login。**架构已落好**（app-secret ownership 分布、file-like
source、host-owned inventory），但运行时仍是单一事务性发布者
（一个 /run/guixcfg-secrets generation publication、fail-closed
全量事务）——区分 login-critical 与 ordinary 需要两个独立发布者/
两个 generation 根，属 secrets subsystem 重构，刻意未做（避免
扩大范围与破坏现有 fail-closed 事务；2026-08 app-layer 重构报告）。
未来：`interactive-secrets-ready` 只代表 login-critical 类。

**收口要求（2026-08）**：在启用第一个 production application
secret 之前，runtime secret publication 必须按 failure/readiness
domain 拆分：

```text
runtime secret publisher mechanism
    ├── login-critical transaction/domain → interactive-secrets-ready
    └── ordinary application transaction/domain → 不阻塞 login
```

composition 发生在 host/system assembly（classification/grouping），
不是 registry、不是 generic publisher。若未来需要 classification，
优先属于具体 `secret-decl` 的 deployment/readiness contract，而
不是整个 `<application>` 的属性。当前 `applications-secrets` 聚合
已实现但**无 system consumer**（刻意保留——见 secrets.md）。

### Application persistence（/persist/data-app）

generic engine 已实现（`system/application-persistence.scm`：
bind-only directory bind、严格 path validation、activation 恢复
consumer parent ownership、三路径安全审计）。**当前无真实 production
application persistence rule**——状态：mechanism ready, production
rules pending explicit application adoption。每新增 rule 必须满足
persistence contract（canonical backing / consumer / exposure /
owner / lifecycle）；backup 是未来独立 concern，不制造 taxonomy。

### stable identity offline-attack boundary

`secrets/bootstrap/stable-identity.age`（passphrase 加密私钥）位于
public repo，给攻击者离线尝试 master passphrase 的目标。长期选择：
public repo 只含 recipient + ciphertext，private identity 另存密码
管理器/离线备份；或维持现状但 master passphrase 必须高熵、独立于
登录密码（当前已独立）。不擅自迁移。

### configctl passwd / password rotation

未来 `configctl passwd` 语义：generate hash → update encrypted
provisioning source → atomically update installed persistent hash →
trigger/revalidate account projection → preserve fail-closed。不能长期
依赖运行期 `passwd user`（只改 ephemeral shadow，reboot 丢失）。

### Application persistence（/persist/data-app）

当前是骨架/规划。每增加一个 app persistence rule 必须指定 canonical
backing、consumer path、bind/symlink/direct、backup class、ownership、
lifecycle。

### Cleanup candidates（疑似 dead，保留待确认）

- `tools/t7-e2e.sh`、`tools/t7-interact.py`、`tools/t7-scenario.sh`、
  `tools/test-tpm2-luks.sh`、`tools/test-tpm2-poc.sh`：历史 TPM/VM
  E2E harness，当前零代码引用（有文档引用）。保留历史价值，命名
  整理待定。
- `tools/format-scheme.mjs`：零引用，疑似死代码。

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
- Desktop / greetd：login gate 从 mingetty 扩展到 greetd。
- Laptop：host 组装点 + 硬件驱动（kernel platform 已就位：
  `(guixcfg system kernel-platform)` 的 standard Linux +
  linux-firmware + Intel microcode 直接复用；实机 firmware 选择与
  microcode revision 验收属 laptop phase）。
- Mihomo / Flatpak 应用管理（docs 已规划，未实现）。
