# Desktop Authentication Architecture

桌面认证基础设施的 authority / session lifecycle / persistence 边界。
两条独立链，**不混成自定义统一 authentication framework**：

```text
POLKIT（system authority）
    polkitd                          ← system D-Bus activation（无 shepherd）
      ↑  system D-Bus
      ↓
    user graphical session
      lxpolkit（apps/lxpolkit）      ← niri spawn-at-startup（会话唯一 owner）
      register AuthenticationAgent
      ↓
    polkitd → 授权检查 → lxpolkit 图形密码提示
```

```text
SECRET SERVICE（login keyring，两阶段 lifecycle）
    greetd PAM auth（service "greetd"）
      ↓ 用户登录密码（同一 PAM transaction）
    pam_gnome_keyring.so（auth：保存 token）
      ↓
    pam_gnome_keyring.so auto_start（session）——Phase 1：--login
      ↓ 以用户身份启动 gnome-keyring-daemon --daemonize --login
    （stub：只解锁/创建 login keyring，不完成初始化；
      120 秒无 --start 接管自动退出——gkd-main.c LOGIN_TIMEOUT）
      ↓
    niri spawn-at-startup（session）——Phase 2：--start
      ↓ gnome-keyring-daemon --start --components=secrets
    接管同一 daemon、完成初始化、自身退出（上游语义）
      ↓
    gnome-keyring-daemon / org.freedesktop.secrets
      ↓
    ~/.local/share/keyrings  ←bind─ /persist/data-app/gnome-keyring/keyrings
```

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
- `lxpolkit`（apps/lxpolkit，binary 来自 lxsession 包）是 **graphical
  session agent**：niri `spawn-at-startup` 启动一次、会话结束自然
  结束；不拥有 polkitd / rules / system D-Bus；无 persistence、
  无 declarative secrets。

## 2. Secret Service：PAM 登录链

### 2.1 官方 service（pinned `gnu/services/desktop.scm:2004`）

`gnome-keyring-service-type` 只扩展 `pam-root-service-type`。
`<gnome-keyring-configuration>` 的 `pam-services` 是 alist：

- `("<pam-service>" . login)` → 该 service 的 auth 追加
  `pam_gnome_keyring.so`（optional，保存密码 token）；session 追加
  `pam_gnome_keyring.so auto_start`（optional，解锁 + 启动 daemon）；
- `("<pam-service>" . passwd)` → password 段追加
  `pam_gnome_keyring.so`（passwd 改密码时同步 keyring 密码）。

pinned 默认是 `gdm-password`——本系统不用 gdm，**整体替换**为实际
使用的 service（apps/gnome-keyring/definition.scm）：

```scheme
(pam-services '(("greetd" . login)
                ("login" . login)
                ("passwd" . passwd)))
```

- `"greetd"`：greetd 会话 PAM service（pinned `base.scm:4385`
  `unix-pam-service "greetd"`；greetd 运行时 PAM service 名即
  `"greetd"`——`config/mod.rs` `GENERAL_SERVICE`）。用户会话的
  登录 keyring 解锁 + daemon 启动都在这里；
- `"login"`：mingetty tty2-6 console fallback（同一解锁路径）；
- `"passwd"`：密码修改同步 keyring 密码。

### 2.2 Daemon lifecycle：两阶段（PAM `--login` + session `--start`）

**pinned 审计（gnome-keyring-48.0 源码，`gkd-main.c` 注释明示）：**

```text
Phase 1（PAM，--login）：
  pam_gnome_keyring.so auto_start 以用户身份启动
  gnome-keyring-daemon --daemonize --login
  ——只解锁/创建 login keyring 的 stub，不完成初始化；
  ——LOGIN_TIMEOUT 120 秒：无 --start 接管则自动退出
    （gkd-main.c:106-110, 825, 1114）；
  ——即使 session 阶段以 root 运行（greetd worker 在 fork+setuid
    之前 pam_open_session——worker.rs:222,245），模块 fork 的子进程
    会 seteuid(getuid()) → setgid/setuid(pw_uid) 降权到 PAM 用户
    再 execve daemon（pam/gkr-pam-module.c）——daemon、keyring 文件、
    control socket 全部归用户。

Phase 2（session，--start）：
  session startup 必须再执行 gnome-keyring-daemon --start：
  通过 control socket 接管 Phase 1 的 stub、把它接入会话环境、
  完成初始化——"This second daemon usually exits"（gkd-main.c）。
```

本仓库的 Phase 2 由 **niri spawn-at-startup** 提供
（`apps/niri/config.kdl`：`spawn-at-startup "gnome-keyring-daemon"
"--start" "--components=secrets"`）。这是 **architectural
compromise**：Secret Service 本质是 user-session infrastructure，
理想 owner 是 Home Shepherd/session manager；但当前架构（M2）唯一
的 graphical-session startup 是 niri（greetd → bash -l → Home
Shepherd → niri），niri 启动时 session D-Bus 已就绪（home-niri
requirement home-dbus），spawn 落在 120 秒接管窗口内。若未来引入
通用 XDG autostart runner 或 session manager，Phase 2 应迁移到该层
（AGENT.md §15）。

**D-Bus activation 不是完整 session startup 的等价替代**：两个
D-Bus service file（org.freedesktop.secrets / org.gnome.keyring）
都是 `--start --foreground --components=secrets`——同样是 --start
语义。stub 存活窗口（120 秒）内，D-Bus activation 能接管它；stub
超时退出后，activation 启动的是**全新 daemon——login keyring 未
解锁**（会弹 keyring 密码提示）。因此 PAM-only 部署的后果是：登录
后 120 秒内 Secret Service 是未初始化的 stub，120 秒后 daemon 消失
（`pgrep -a gnome-keyring-daemon` 无输出——实测现象），再次访问时
由 D-Bus activation 拉起的 daemon 处于 locked 状态。

**单实例**：daemon `--start` 先 `discover_other_daemon`
（`gkd-main.c`）——PAM stub、--start initializer、D-Bus activation
最终都指向同一 logical daemon；重复启动是 no-op。

**禁止**：shell / session script / Home Shepherd 手动再启动
`gnome-keyring-daemon`（测试 GK5 断言——唯一 invocation 是 niri
config 的 spawn）。

### 2.3 Keyring storage

daemon 默认 vault：`g_get_user_data_dir()/keyrings` =
`~/.local/share/keyrings`（pinned 源码 `daemon/dbus/gkd-secret-service.c:171`）。

```text
/ persist/data-app/gnome-keyring/keyrings
        ↓ bind-directory（application-persistence）
~/.local/share/keyrings
```

这是 **application/user-owned sensitive mutable state**——不是
machine-state、不是 declarative .age secret、不是 data-home。

### 2.4 不持久化 runtime

以下每 session/boot 重建，禁止 persistence：

```text
/run/user/<uid>/...
/run/user/<uid>/keyring（control socket）
XDG_RUNTIME_DIR、D-Bus session socket
polkit 临时授权状态
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

## 5. 迁移（no implicit migration）

`~/.local/share/keyrings` 若在首次启用 persistence 前已有非空数据
（例如旧会话直接写在 ephemeral home 里），**不会自动迁移**——bind
mount 会覆盖旧目录，ephemeral root 重建后旧数据消失。人工迁移步骤：

```text
1. 备份旧目录：cp -a ~/.local/share/keyrings /tmp/keyrings.bak
   （在启用 rule 前的旧 generation 会话内，mount 尚未覆盖时）
2. 启用 rule、reconfigure、登录一次（mount 就位）
3. 停掉 gnome-keyring（logout）
4. root：把备份内容复制到 backing：
   cp -a /tmp/keyrings.bak/. /persist/data-app/gnome-keyring/keyrings/
   chown -R user:users /persist/data-app/gnome-keyring/keyrings
5. 重新登录验证 secret-tool lookup
```

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
| pam 模块降权 + exec daemon | gnome-keyring `pam/gkr-pam-module.c` |
| 两阶段 lifecycle（--login stub → --start 接管） | gnome-keyring `daemon/gkd-main.c`（注释明示） |
| --login stub 120 秒超时退出 | gnome-keyring `gkd-main.c` `LOGIN_TIMEOUT` |
| D-Bus activation = --start --foreground | gnome-keyring `daemon/*.service.in` |
| daemon 单实例（--start discover） | gnome-keyring `daemon/gkd-main.c` |
| daemon 延迟接管 session bus | gnome-keyring `daemon/gkd-util.c` |
| vault 路径 XDG_DATA_HOME/keyrings | gnome-keyring `daemon/dbus/gkd-secret-service.c:171` |
| session bus 默认扫描 XDG service dirs | dbus `session.conf` `<standard_session_servicedirs/>` |

## 7. Runtime acceptance（VM manual）

1. greetd 输入用户密码登录：session 成功、elogind session active、
   无额外 keyring 密码弹窗；
2. 登录后（不用等）：`pgrep -a gnome-keyring-daemon`——daemon 存在
   且**持续存在**（Home Shepherd initializer 完成 --start 接管，
   不再有 120 秒超时退出）；`ps -o user,pid,ppid,cmd -p <pid>`
   确认 user 所有、单进程；
3. `busctl --user list | grep secrets` 或
   `guix shell libsecret -- secret-tool search --all ''` 可访问
   `org.freedesktop.secrets`；
4. store：`guix shell libsecret -- secret-tool store --label=guixcfg-secret-service-test guixcfg=test <sentinel>`
   （synthetic sentinel，非真实密码）；
5. lookup 立即成功（无 keyring 密码提示）；
6. 等 3 分钟再 `pgrep`：daemon 仍在（验证 LOGIN_TIMEOUT 已被
   initializer 消除）；
7. reboot → 同一登录密码登录 → lookup 成功且不再要求 keyring 密码
   （证明 PAM unlock + --start 接管 + data-app persistence +
   runtime 重建）；
8. logout → login 再测一次；
9. `/run/user/<uid>/...` 在 session 间重建，不来自 /persist；
10. polkit：图形会话内 `pkexec id` → 提示来自 lxpolkit（图形）而非
    textual fallback；认证成功；cancel 正常；无两个 agent 抢同一
    prompt。

决定性实验（修复前确认根因，可选）：登录后（stub 存活窗口内）手动
`gnome-keyring-daemon --start` → `secret-tool lookup` 立即成功 →
证明缺的是 session 初始化阶段（PAM --login 本身正常）。
