# Desktop Authentication Architecture

桌面认证基础设施的 authority / session lifecycle / persistence 边界。
两条独立链，**不混成自定义统一 authentication framework**：

```text
POLKIT（system authority）
    polkitd                          ← system D-Bus activation（无 shepherd）
      ↑  system D-Bus
      ↓
    user graphical session
      polkit-gnome（apps/polkit-gnome）← niri spawn-at-startup（会话唯一 owner）
      register AuthenticationAgent
      ↓
    polkitd → 授权检查 → polkit-gnome 图形密码提示
```

```text
SECRET SERVICE（repository-owned master credential model）
    apps/gnome-keyring/secrets/master.age（encrypted，repo owner）
      ↓ existing guixcfg secret publisher（ordinary domain）
    /run/guixcfg-secrets-ordinary/users/<user>/gnome-keyring-master
      （owner=<user>，mode 0400；明文仅存在于 /run——用户明确接受）
      ↓
    Home Shepherd session service（gnome-keyring-session）
      requirement: session D-Bus
      ↓ wrapper：stdin 文件重定向注入密码（无 argv/env）
    gnome-keyring-daemon --foreground --unlock --components=secrets
      ↓ 单一 daemon、启动即解锁/创建 login keyring
    org.freedesktop.secrets
      ↓
    ~/.local/share/keyrings  ←bind─ /persist/data-app/gnome-keyring/keyrings
```

login authentication（greetd/PAM）与 keyring unlocking（本服务）完全
分离——不共享 password lifecycle；`passwd` 不再同步 keyring 密码。

## 1. Polkit：system authority

- `polkitd` 属于 **system**：官方 `polkit-service-type`
  （pinned `gnu/services/dbus.scm:403`）。polkitd **没有 shepherd
  服务**——由 system D-Bus 按需 activation 启动（dbus-root 扩展拿到
  polkit 包的 system service file）。
- `elogind-service-type`（pinned `desktop.scm:1779`）扩展
  `polkit-service-type`（elogind 自己的 polkit actions）与
  `dbus-root-service-type`——`instantiate-missing-services`
  （pinned `system.scm:891`）因此**隐式物化 polkitd 与 system D-Bus**。
  `%common-services` 再显式声明 `(service polkit-service-type)` +
  `polkit-wheel-service`，让 authority 与 admin policy 在配置中可见。
- `polkit-wheel-service`（pinned `desktop.scm:2673`）是 **admin
  identity 声明**（`polkit.addAdminRule(unix-group:wheel)`），不是
  blanket allow。wheel 是既有 account 语义（`users/user.scm`）。
- **本仓库不写自定义 `/etc/polkit-1/rules.d`**（测试断言唯一
  rules/actions 贡献 = elogind + polkit-wheel）。
- `polkit-gnome`（apps/polkit-gnome）是 **graphical session agent**：
  niri `spawn-at-startup "polkit-gnome-authentication-agent-1"` 启动
  一次、会话结束自然结束。agent 二进制在 libexec（不在 PATH，无 FHS
  路径）——app 经 home-files 提供 `~/.local/bin` wrapper（store 路径
  由 guix 构建期注入，仓库无 store 字面量）并把 `~/.local/bin`
  加入 session PATH。不拥有 polkitd / rules / system D-Bus；无
  persistence、无 declarative secrets。

## 2. Secret Service：repository-owned master credential

### 2.1 Authority model（2026-08 正式切换）

旧模型（pam_gnome_keyring login-password handoff）**彻底退出**：

```text
Unix login password → PAM_AUTHTOK → pam_gnome_keyring → --login stub
→ --start handoff → Secret Service        （已删除）
```

新模型：

```text
apps/gnome-keyring/secrets/master.age（encrypted，app-owned）
    ↓ guixcfg ordinary secret publisher（boot 时 root 解密）
/run/guixcfg-secrets-ordinary/users/<user>/gnome-keyring-master
    （owner=<user>，mode 0400——plaintext 仅存在于 /run，用户明确接受）
    ↓ Home Shepherd session service
gnome-keyring-daemon --foreground --unlock --components=secrets
    ↓ 单一 daemon；stdin 注入密码；启动即解锁/创建 login keyring
org.freedesktop.secrets
```

核心 separation：

```text
login authentication（greetd/PAM）≠ keyring unlocking（session service）
```

- greetd/PAM 决定"能否登录"；本服务决定"会话能否解锁其 vault"；
- 两者不共享 password lifecycle；`passwd` 只改 Unix 密码，**不再
  同步 keyring 密码**（设计目标，不是 regression）；
- keyring master credential 是 **stable credential**：normal
  reconfigure 不轮换；rollback 不回滚 mutable vault；rotation 是
  显式维护操作（先 rekey vault，再切换 runtime secret）。

### 2.2 PAM 完全退出

`/etc/pam.d/greetd`、`/etc/pam.d/login`、`/etc/pam.d/passwd` 均无
`pam_gnome_keyring.so`（测试 GK2 断言）。`gnome-keyring-service-type`
不再实例化；greetd-greeter 专用 PAM service 已删除（其唯一存在理由
——防止 greeter 会话回退到带 keyring 的 "greetd" 栈——随 PAM
keyring 退出而消失；greeter 会话现在走无 keyring 的 "greetd" 栈，
不会产生任何 daemon）。

### 2.3 Daemon invocation（pinned gnome-keyring-48.0 审计，Model 1）

```text
gnome-keyring-daemon --foreground --unlock --components=secrets
    < /run/guixcfg-secrets-ordinary/users/<user>/gnome-keyring-master
```

pinned 语义（`gkd-main.c`）：

- `--unlock`：从 stdin 全量读取密码（含换行都算密码——加密时无尾
  换行）；`--unlock` + `--foreground` 组合合法（仅 `--start`+`--unlock`
  互斥）；
- 不带 `--login`：daemon **正常完整初始化**（不是 stub）——login
  keyring 解锁/创建在 initialization 块无条件执行
  （`gkd-main.c:763` `gkd_login_unlock(login_password)`），与
  `--components` 无关；`--components=secrets` 只控制 Secret Service
  注册；
- `--foreground`：不 daemonize——Shepherd 直接追踪 PID；SIGTERM →
  `gkd_main_quit` 干净退出；
- 失败语义：密码错误 → "failed to unlock login keyring on startup"
  （daemon 继续运行但 locked）；secret 文件缺失 → 重定向失败 →
  服务失败（shepherd 状态可见，登录不受影响——ordinary domain）。

### 2.4 会话服务（单一 lifecycle owner）

`apps/gnome-keyring` 的 home-services：

- Home Shepherd 服务 `gnome-keyring-session`（requirement `dbus`，
  one-shot——daemon 退出 = 会话结束，不 respawn）；
- wrapper（program-file）：检查 control socket（同一用户已有 daemon
  则 no-op 退出——每用户单 daemon）→ 密码经 stdin 文件重定向 →
  exec foreground daemon；
- 密码不出现于 argv/env/日志；日志只有 daemon stderr。

D-Bus activation（org.freedesktop.secrets.service 的
`--start --foreground`）仍是 fallback：本服务在会话启动早期占有
bus name，activation 不会触发；服务失败时客户端访问才可能激活
（locked 状态）。不存在 split-brain（单 daemon 设计）。

### 2.5 Keyring storage

daemon 默认 vault：`g_get_user_data_dir()/keyrings` =
`~/.local/share/keyrings`（pinned `daemon/dbus/gkd-secret-service.c:171`）。

```text
/persist/data-app/gnome-keyring/keyrings
        ↓ bind-directory（application-persistence）
~/.local/share/keyrings
```

application-owned sensitive mutable state——不是 machine-state、不是
declarative .age secret、不是 data-home。

### 2.6 不持久化 runtime

以下每 session/boot 重建，禁止 persistence：

```text
/run/user/<uid>/...（含 keyring control socket）
XDG_RUNTIME_DIR、D-Bus session socket
```

## 3. Declarative secrets vs Secret Service secrets

```text
guixcfg declarative secret            Secret Service secret
  repo authority                         runtime application/user authority
  encrypted .age → secret-decl           应用经 libsecret / D-Bus 写入
  → /run/guixcfg-secrets                 → persistent keyring vault
```

两者不互相转换。未来 Chrome Safe Storage 材料属于后者；预声明的
deployment API token 属于前者。

## 4. 安全语义

- keyring vault 视为 sensitive high-value data：不进 Git、不进 store、
  日志不输出内容；tests 只用 synthetic sentinel。
- 不做“keyring 文件再 age 加密一层”。
- **登录 keyring 自动解锁依赖登录 PAM 认证流**（密码在 PAM
  transaction 内传递）。autologin / fingerprint / FIDO-only /
  TPM-to-keyring / LUKS password forwarding 明确 out of scope；
  未来改变登录认证方式时，需单独设计 keyring unlock。

## 5. Vault 状态与迁移

- 基础设施**绝不自动 destructive-reset vault**（不删除/覆盖/重建
  keyring 文件）；
- 若现存 vault 的密码与配置的 master credential 不一致：解锁失败
  （daemon 运行但 locked）——需**人工 rekey** 现有 vault 到配置的
  master credential（显式维护操作），或（仅测试 VM、确认无真实数据
  时）人工删除重建一次；
- `~/.local/share/keyrings` 若在启用 persistence 前已有非空数据：
  **不自动迁移**（no-implicit-migration 不变量）——人工迁移步骤见
  旧文档记录；secret vault 不允许"尽力迁移"。

## 6. Pinned source map（94a84f9）

| 事实 | 位置 |
|---|---|
| polkit-service-type | `gnu/services/dbus.scm:403` |
| polkit-wheel-service（addAdminRule wheel） | `gnu/services/desktop.scm:2673` |
| elogind 扩展 polkit/dbus-root/pam | `gnu/services/desktop.scm:1779-1805` |
| gnome-keyring-service-type | `gnu/services/desktop.scm:2004-2067` |
| greetd PAM service（"greetd"） | `gnu/services/base.scm:4385-4410` |
| greetd 运行时 PAM service 名 | greetd `config/mod.rs` `GENERAL_SERVICE` |
| greetd session 阶段先于 setuid（worker） | greetd `session/worker.rs:222,245` |
| --unlock 从 stdin 全量读密码（含换行） | gnome-keyring `daemon/gkd-main.c` `read_login_password` |
| --unlock 合法组合（--foreground；--start 互斥） | gnome-keyring `gkd-main.c` parse_arguments |
| login keyring 解锁无条件（initialization 块） | gnome-keyring `gkd-main.c:763` `gkd_login_unlock` |
| --foreground 不 daemonize；SIGTERM 干净退出 | gnome-keyring `gkd-main.c` `on_signal_term` |
| D-Bus activation = --start --foreground（fallback only） | gnome-keyring `daemon/*.service.in` |
| daemon 单实例（discover_other_daemon） | gnome-keyring `daemon/gkd-main.c` |
| 每用户单 daemon（control socket 独占） | gnome-keyring `daemon/control/gkd-control-server.c` |
| vault 路径 XDG_DATA_HOME/keyrings | gnome-keyring `daemon/dbus/gkd-secret-service.c:171` |
| session bus 默认扫描 XDG service dirs | dbus `session.conf` `<standard_session_servicedirs/>` |

## 7. Runtime acceptance（VM manual）

1. greetd 输入用户密码登录：session 成功、elogind session active；
2. `pgrep -a gnome-keyring-daemon -f`：**恰好一个**
   `--foreground --unlock --components=secrets`（无 `--login`、
   无 `--start`、无第二个 daemon）；
3. `ls -la /run/user/<uid>/keyring/`：control socket 稳定存在；
4. `busctl --user list | grep secrets`：org.freedesktop.secrets →
   该 daemon PID；
5. store：`guix shell libsecret -- secret-tool store --label=guixcfg-keyring-test guixcfg keyring-test <synthetic>`
   ——无 keyring 密码提示；
6. lookup 立即返回；`sleep 180 && pgrep`：daemon 仍在（无 120s
   超时问题——本模型无 stub）；
7. reboot ×3 + logout/login：每次登录后 lookup 直接成功，无需额外
   keyring 密码；
8. failure path：临时使 master secret 不可用（不破坏 ciphertext）→
   greetd login 与 niri 会话正常，keyring 服务 failed/unavailable，
   登录不受影响。
