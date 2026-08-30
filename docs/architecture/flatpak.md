# Flatpak Architecture

Flatpak 是本仓库的**外部桌面软件子系统**：Guix 声明 policy /
integration / desired applications，Flatpak 自己拥有 mutable per-user
installation state。**Flatpak 不是第二套 Guix package abstraction，
不被伪装成 Guix package。**

核心边界（必须诚实接受）：

```text
Guix generation ≠ Flatpak installation generation
```

不存在统一的 rollback 语义：Guix rollback 只回滚声明侧（session env、
override 文件、desired state）；已安装 refs 与 `~/.var/app` 数据是
mutable external state，不随 generation 回滚。`flatpak status` 如实
报告 divergence。

## 五层模型

```text
1. Host / Selection        sync 应该 ensure 哪些 logical names
2. Flatpak Applications    Catalog：identity + resource ownership
3. Flatpak Platform        remote / desired-state / reconcile /
                           overrides / validation（generic，不知具体 app）
4. Guix Home + System      package / session env / persistence 接线
5. Persistent Runtime      /persist/data-app/flatpak/{installation,apps/<id>}
```

## Application model（definition / registry / selection / projection）

Flatpak 应用与仓库原生应用同构：**自包含 definition + 纯聚合
registry + logical selection + generic projection**。

```text
applications/<name>.scm          definition = 应用是什么（全部业务事实）
    ├── identity                logical name、Flatpak app-id
    ├── ref metadata            remote、branch
    ├── update policy           'track-branch | (flatpak-commit-pin "<hex>")
    ├── override policy         'external | (managed-overrides <flatpak-override>)
    └── persistence intent      默认 ~/.var/app/<id>（ID 推导）+ extra-persistence 例外
registry.scm                     纯 aggregation：import definitions → %flatpak-applications；
                                 %flatpak-selection（logical names）；%flatpak-remotes；统一校验
service projection（offline）    selected definitions → persistence rules + managed override 文件
reconcile projection（mutable）  selected definitions → install/update plan
```

- **definition 是事实的唯一归属**：打开 `applications/qq.scm` 就能
  读完一个应用的全部声明；registry 只是索引，不含任何 inline
  `flatpak-application` 记录。
- **selection 只选择**：`%flatpak-selection = '(qq)` 只含 logical
  names，不复制 id/branch/persistence；resolver
  （`flatpak-select-applications`）做 catalog lookup（未知 name
  fail-fast 并列出可用名）。即使 VM/Laptop 相同也独立存在：
  **desired lifecycle ≠ persistence lifecycle** 的结构分离。
- **persistence 从 selected definitions 投影**：未选中的 catalog
  app 不产生 persistence mount（其 definition 里的 persistence
  intent 随 selection 生效）；默认 `~/.var/app/<id>` 由 application
  ID 推导（definition 无需重复拼写），例外用 extra-persistence
  （(consumer backing) 两元素列表，与 seeds 约定同构）。
- **新增应用 = 一个 definition 文件 + registry aggregation 一行 +
  selection 一行**；service/persistence/host 表格零改动。

### 生命周期（Case A–D）

| Case | Catalog | Selection | Installed | Persistence bind |
|---|---|---|---|---|
| A 正常态 | 有 | 有 | 有 | 有 |
| B 从 selection 删除 | 有 | **无** | **仍在** | **随 reconfigure 消失**（selection 投影——用户明确表示"本设备不再要它"，新写入不再持久化；backing 内旧数据保留到显式 purge） |
| C 显式 remove | 有 | 无 | 无 | 仍在（userdata 保留，owner 清晰） |
| D 显式 purge | 有 | 无 | 无 | 内容清空、规则仍在；**之后**才允许从 Catalog 删除定义 |

```text
selection removal = 非破坏性（sync 不再 ensure；ref 不卸载；旧数据不删除；
                     仅新 generation 不再投影其 mount——行为变化记录见 git 历史）
catalog definition removal = lifecycle teardown 的最后一步（purge 之后）
declaration removal 不是"永久销毁用户数据"的充分授权
```

## Persistence

```text
/persist/data-app/flatpak/installation     → ~/.local/share/flatpak   （平台拥有）
/persist/data-app/flatpak/apps/<app-id>    → ~/.var/app/<app-id>      （selected app 的 definition 拥有）
```

- **persistence intent 属于 application definition**：默认
  `~/.var/app/<id>` 由 application ID 推导（service 投影显式实现，
  definition 无需重复拼写）；例外经 `extra-persistence`
  （(consumer backing) 两元素列表）在 definition 里声明。投影从
  **selected** definitions 派生（`flatpak-persistence-rules` =
  installation + selected apps 的 intent）——未选中的 catalog app
  不产生 mount。
- 全部经 `(guixcfg system application-persistence)` generic engine
  （bind-directory + activation backing/owner + home-path helper）——
  **零 Flatpak 专属 mount 代码**；host 组装点
  （`hosts/vm.scm`）把 `flatpak-persistence-rules` 与
  `applications-persistence` 一起交给 engine。
- installation 是**一个完整 persistence unit**：repo/remotes/
  exports/overrides 内部结构由 Flatpak 自己管理，不拆。
- `~/.var/app/<id>` 整体持久化（含 sandbox 内 cache——不做目录
  白名单，reliability 优先）。
- **不**持久化整个 `~/.var/app`；**不**使用 data-nobackup（它保持
  direct-access-only 语义，"能否重新下载"不等于"进哪个 persistence
  mechanism"——installation 需要 canonical bind，属 data-app）。
- `flatpak/installation` 与 `flatpak/apps/<id>` 是**平级** backing，
  禁止 parent/child mount 嵌套（`tests/test-flatpak-persistence.scm`
  回归固定）。

## Remotes 与 trust（identity / bootstrap authority / transport）

```scheme
(flatpak-remote
  (name 'flathub)                                                  ; identity
  (descriptor-url "https://dl.flathub.org/repo/flathub.flatpakrepo") ; bootstrap + trust authority
  (repository-url "https://mirror.sjtu.edu.cn/flathub")              ; desired transport
  (comment "Flathub via SJTU mirror"))
```

- **我们完全信任官方 descriptor**：`descriptor-url` 指向的官方
  `.flatpakrepo` 是该 remote 的权威 trust material（内嵌 GPGKey）。
  **trust lifecycle 由 upstream 持有**——官方续期/轮换密钥后，下次
  bootstrap / remote-replace 自然获取最新 key；仓库不 vendor key
  文件、不 pin fingerprint、不维护过期日期、不做轮换人工审批。
- **repository-url 是唯一 transport 事实**（drift 检查基线 +
  canonicalize 目标）；SJTU 镜像只改变 transport，不改变 identity
  与 trust。
- 换源 = 改 `repository-url` → `tools/flatpak.scm remote-replace
  <name>`（显式）；换 trust authority = 改 `descriptor-url`。
- **当前 declarative remote 契约要求官方提供 bootstrap descriptor**
  （Case A/B）；无 `.flatpakrepo` 的 remote（Case C）不在模型内，
  实际遇到时再扩展 bootstrap strategy sum type——不提前设计。

### Bootstrap（封装为领域操作，见 reconcile.scm）

`flatpak-bootstrap-remote!` 封装 pinned Flatpak 1.16.6 的 bootstrap
语义，调用方不需要理解：

```text
remote-add --user --if-not-exists --from NAME <descriptor-url>
                         ← flatpak 下载官方 descriptor、导入其当前
                           GPGKey（--from 直接接受 URL，1.16.6 实测；
                           descriptor 下载失败 = bootstrap 失败，
                           绝不 fallback 到镜像 descriptor / 缓存 /
                           --no-gpg-verify / 裸 URL）
remote-modify --user --url=<repository-url> NAME
                         ← canonicalize：add 阶段抓取 summary 时会
                           【无条件】应用其 xa.redirect-url（Flathub
                           的 summary 指回官方——镜像 URL 被改写；
                           --no-follow_redirect flag 在 --from 路径
                           上无效，VM -vv 实测）；modify 不抓 summary、
                           redirect 是显式 opt-in；落定后 install/
                           update/remote-ls 的 summary 抓取不再改写
                           URL（VM 实测）
partial-failure rollback ← modify 失败时只删除【本次调用创建】的
                           remote（调用前提 = check-remote! 为 #f），
                           不留半配置状态
```

### Remote reconciliation（sync 的 check）

```text
remote 不存在          → flatpak-bootstrap-remote!（建立 + canonicalize）
remote 存在且 url 一致   → no-op（不重新 bootstrap、不重新取 descriptor）
remote 存在但 url 不一致 → FAIL + actionable diagnostic
                        （绝不自动 remote-modify/delete，不静默改 trust root）
```

**trust rotation 与 transport drift 是两个不同问题**：前者在显式
bootstrap 时静默接受（官方 descriptor 是权威）；后者在普通 sync
永远 fail-loud（transport 是仓库声明，换源必须显式
`remote-replace`）。镜像注意：国内镜像通常智能缓存——未缓存文件
重定向回官方源、NVIDIA 等受限内容必须走官方服务器；镜像站发布的
`.flatpakrepo` 可能是官方 descriptor 原样转发（`Url=` 仍指向官方），
因此 bootstrap 一律使用**官方** descriptor-url，绝不从镜像建立
trust。

## Overrides：complete-file ownership

有 repo declaration 的 app：`(guixcfg flatpak service)` 经
home-files 生成**完整** `~/.local/share/flatpak/overrides/<app-id>`
（deterministic GKeyFile renderer——store symlink = derived state，
随 generation/rollback）。无 declaration：仓库不产生文件，user /
Flatseal owns。**repo 与 Flatseal 永不 merge-write。**

repo-owned override 是 **read-only declarative state**，不建议直接
用 Flatseal 修改（pinned Guix Home symlink-manager 的真实行为：
declaration 恢复时 existing user file 会被移入
`~/<timestamp>-guix-home-legacy-configs-backup/` 再重建 symlink——
该目录位于 ephemeral HOME，本机跨 boot 不保留）。实验流程：

```text
1. overrides declaration → #f
2. reconfigure（cleanup-symlinks 删除旧 store symlink，路径回归 user-owned）
3. Flatseal / flatpak override 实验
4. flatpak override --show --user <id>
5. 整理真正需要的 delta
6. 写回 Scheme declaration（带注释说明原因）
7. reconfigure（repo 重新取得 authority）
```

## Operations（唯一联网入口 = tools/）

```bash
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- sync
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- status [--refresh]
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update-runtimes
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- remove <logical-name>
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- remote-replace <remote-name>
guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- gc
```

| 命令 | 语义 |
|---|---|
| `sync` | ensure remotes + ensure selected apps（**只增不删**：不 update 已装、不 uninstall 未声明、不 gc）。pin app：install 后 `update --commit=<H> <ref>`（pinned 1.16.6 的 install 无 `--commit`） |
| `status` | 完全离线：logical name / app-id / selected? / installed? / branch / declared commit / installed commit。`--refresh` 才 remote-info（失败显示 unknown，不破坏本地输出） |
| `update` | 目标 = **selection ∩ installed ∩ unpinned**，显式 ref 列表；绝无无参全 installation update；commit pinned app 默认不进目标 |
| `update-runtimes` | 枚举 installed runtimes → 显式 ref 更新（app pin 不隐含 runtime pin） |
| `remove` | 显式 uninstall ref（logical name，catalog fail-fast 解析）；**userdata 与 persistence rule 保留（remove ≠ purge）** |
| `remote-replace <name>` | **唯一换源入口**：显式 destructive acknowledgment——remote-delete + 按声明 bootstrap 重建（生成的 descriptor + keyring）；sync 的 drift 检查永远 fail-loud，绝不自动改 trust root |
| `gc` | 显式维护：`uninstall --unused --user` + `repair --user`；不挂任何 hook |
| `purge` | Phase 4（seam 已定义）：remove ref + 清空 userdata **内容**（绝不 `rm -rf` 仍 bind-mounted 的 backing root）；之后才允许从 Catalog 删除定义 |

**网络边界（硬不变量）**：reconfigure / boot / home activation /
login gate 不做任何联网 flatpak 操作（remote-add/install/update/
remote-info/repair）。`(guixcfg flatpak service|model|registry)` 不
import `(guixcfg flatpak reconcile)`、不含 CLI 调用面
（`tests/test-flatpak-service.scm` 静态回归固定）。所有操作显式
`--user`（无 system installation、无 `/var/lib/flatpak`）。

## System / Home integration 归属

| 集成点 | Owner | 说明 |
|---|---|---|
| flatpak executable | Guix System（`system/packages.scm`） | 一切安装走 `--user`；`FLATPAK_BINARY` 经 `/etc/profile` 进会话 |
| XDG_DATA_DIRS | Flatpak 平台 Home service | `$XDG_DATA_DIRS:$HOME/.local/share/flatpak/exports/share`（追加不覆盖；launcher 经此发现 desktop entries） |
| fonts | `(guixcfg fonts)` 单一事实源 | `%fonts` 同时进 Home profile 与 System profile 投影——pinned flatpak 补丁只暴露 `/run/current-system/profile/share/fonts` 进 sandbox |
| portal | 现有 niri 栈（零新增） | niri home profile 三件套 + repo-owned `niri-portals.conf`；Flatpak 只是 portal client |
| Secret Service | 现有 gnome-keyring 栈 | Flatpak 应用默认无 secrets 权限；portal Secret 或 per-app override `session-bus` |

## Update policy（显式领域语义，弱于 Guix pin）

definition 的 update-policy 显式表达：

```scheme
(update-policy 'track-branch)                 ; 默认：跟随 branch
(update-policy (flatpak-commit-pin "<hex>"))  ; optional pin（必须注释理由）
```

只有 regression 规避 / 特殊版本要求 / 排查期才 pin。pin 不等价
Guix source pin：remote 可 prune 历史 commit、无自建 mirror——因此
**不设 mandatory lockfile、不自动记录 installed commit**。app pin
不隐含 runtime pin；不实现 Flatpak dependency lock。

## Non-goals

```text
不把 Flatpak 做成 Guix package / generation
不做 system-wide Flatpak（/var/lib/flatpak）
不做 transactional staging installation
不默认 pin 全部 OSTree commits、不建 mandatory lockfile
reconfigure 不联网；不自动 update / remove / purge
不持久化整个 ~/.var/app；data-nobackup 不承担 canonical bind
不写第二套 persistence engine；不另起 portal/keyring 栈
Flatseal 与 repo 不 merge-write 同一 declared override
不为主题一致写 per-app filesystem hacks
```

## 测试与验收

- 离线 suite：`tests/test-flatpak-{model,persistence,service,
  reconcile-exec}.scm`（模型/校验/plan/renderer fixture、persistence
  规则与命名空间回归、composition + 零 CLI 静态回归、fake binary
  运行时 argv 断言——全部 `--user`、sync 只增、drift fail、pin 两步、
  update 显式 refs、status 默认离线、network failure 干净传播）。
- VM acceptance（manual/online，不进默认套件）：reconfigure →
  binary 可用 → sync 加 remote → 装一个 app → Noctalia launcher
  可见 → reboot 零重下载 → `~/.var/app/<id>` 存活 → 中文字体可接受
  → portal（FileChooser/OpenURI/Screenshot 可行项）→ renderer 输出
  与 `flatpak override --show` 交叉验证。Flathub 因 proxy/CA 失败时
  记录 TLS 错误，不误判为架构失败，不关闭 GPG/TLS 验证。
