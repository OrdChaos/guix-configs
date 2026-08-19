# Application Layer（架构参考）

用户态配置的纵向组织单元。**How-to（新增应用）见
`docs/development/applications.md`**；开发约束摘要见 AGENT.md §12。

## 为什么存在（旧问题）

重构前，一个应用被横向拆散：

```text
home/packages.scm        包（git/ripgrep/niri 混在一起）
home/user.scm            服务与 config 引用
files/                   公开配置文件（niri/config.kdl 等）
security inventory       具体 secret 混在 generic mechanism 里
filesystem declarations  持久化规则散落
```

现在应用是 **vertical ownership unit**：

```text
apps/<app>/
├── definition.scm        声明入口（唯一）
├── 公开静态素材           colocate（config.kdl、theme.css、config.toml）
└── secrets/               app-private 加密密文（*.age）
```

> app layer 是 **organization/composition layer**，不是新的 package
> manager，也不是 NixOS/RDE module framework——无 dependency
> solver、无 priority、无 override、无 fixpoint、无自动模块发现、
> 无继承。

## `<application>` contract

定义在 `modules/guixcfg/apps/model.scm`（`(guixcfg apps model)`），
五个贡献字段 + 名字：

```scheme
(application
 (name 'foo)                 ; 唯一 logical name（registry 校验）
 (home-packages (list ...))  ; Home profile 显式安装的包
 (home-services (list ...))  ; home service 实例
 (system-services (list ...)) ; 仅少数确需 system-level service 的 app
 (persistence (list ...))    ; <application-persistence-rule>（声明，不实现挂载）
 (secrets (list ...)))       ; <secret-decl>（声明，不实现解密）
```

| 字段 | 语义 | 注意 |
|---|---|---|
| `name` | 唯一 logical application name | registry 加载时查重（fail fast） |
| `home-packages` | Home profile 显式安装的 package | **官方 Home service 自动贡献的包不重复声明**（home-niri 已带 niri/dbus/portal/xwayland-satellite，home-pipewire 已带 pipewire/wireplumber） |
| `home-services` | 优先顺序：1) official Home service；2) `simple-service` extension；3) generic Home/XDG file services | 禁止双 owner（同一能力两个 active 来源） |
| `system-services` | 仅少数真正需要 system-level service 的 app | **不要**用它包装 greetd/accounts/readiness/TPM/UKI/Secure Boot 等核心基础设施 |
| `persistence` | 声明 app-owned mutable canonical state | 只声明 rule，挂载由 `(guixcfg system application-persistence)` 执行 |
| `secrets` | 声明 app 需要的 ciphertext/runtime secret | 只声明，解密/发布由 `(guixcfg security secrets)` 执行 |

聚合（registry → Home/System）：

```scheme
(applications-home-packages %applications)
(applications-home-services %applications)
(applications-system-services %applications)
(applications-persistence %applications)
(applications-secrets %applications)
```

## Application service rule

Application unit 可以贡献 packages / Home services/extensions /
system services/extensions / persistence / secrets。但：

> **Applications do not merge Guix service values.**

共享 Home sink（`home-xdg-configuration-files`、`home-files`、
environment variables 等——多个 app 都可能贡献的 target）必须经
Guix **native service-extension 机制**贡献：

```scheme
(simple-service
 'mpv-xdg-config
 home-xdg-configuration-files-service-type
 `(("mpv/mpv.conf" ,(local-file "mpv.conf"))))
```

而不是：

```scheme
(service home-xdg-configuration-files-service-type ...)
```

原因：canonical target 实例由 `instantiate-missing-services`
（gnu/services.scm）以 default value 自动生成；多个**完整 target
实例**会 ambiguous-target-service（fold 只接受每类一个 sink）。
`service-type-extend` 组合的是 base value + composed extension
value——**不是 generic same-kind merger**（两个 base value 不是
合法 extend 输入）。

aggregator（`applications-home-services`）只做 concatenation；
Guix（不是 guixcfg）拥有服务组合语义。唯一类型的独立 service
（如 `home-niri-service-type`）保持直接 `(service ...)`。

## Directory layout

```text
apps/foo/
├── definition.scm        authority（唯一声明入口）
├── config.toml           公开静态素材 colocate
├── theme.css
└── secrets/
    └── token.age         app-private 加密密文
```

- `definition.scm` = authority；公开素材与密文 colocate 同目录。
- **mutable runtime state 不能放这里**。禁止：

  ```text
  apps/firefox/profile/places.sqlite
  ```

  真正 runtime canonical state 在：

  ```text
  /persist/data-app/firefox/...
  ```

## Source-relative `local-file`

pinned Guix 事实（94a84f9 `guix/gexp.scm`）：`local-file` 是宏，
**literal 相对路径按出现处 source directory 解析**，不依赖进程 CWD：

```scheme
;; 在 apps/niri/definition.scm 里：
(local-file "config.kdl")     ; → modules/guixcfg/apps/niri/config.kdl
```

这是 app-local source 的标准方式。**禁止重新出现跨层相对引用**：

```text
../../../files/...
```

`(guixcfg utils repository-source)` 的 `repository-file` 只用于
**top-level repository/global resources**（如 `secrets/hosts/...`、
`secrets/shared/...`——taxonomy 见 secrets.md），
不替代 ordinary app-local `local-file`。

## Data ownership 决策表

| 数据 | 去向 |
|---|---|
| 可由 repo 确定性重建？ | → Guix Home / System（derived state） |
| 应用产生、需保留、要求标准 HOME/XDG/FHS 路径？ | → `/persist/data-app` + bind projection |
| 用户自己创建/拥有的数据？ | → `/persist/data-home` |
| 大体积、可重新取得、程序主动访问固定路径？ | → `/persist/data-nobackup`（direct access） |
| app-private declarative secret？ | → `apps/<app>/secrets/*.age` → `/run` |
| shared/system/bootstrap/install secret？ | → top-level `secrets/` |
| machine identity/state？ | → `/persist/system` |

**禁止**把以下目录整体纳入 app persistence（consumer 必须精确到
单个应用状态）：

```text
~/.config
~/.local
~/.local/share
~/.cache
```

（其下应用子目录如 `.config/foo`、`.local/share/foo` 是合法精确
consumer——见 `docs/architecture/persistence.md`。）

**State 决策树**（mutable state 持久化选择）：

```text
Does the application have mutable state?
    no  → Home config only
    yes
Can state live in separate state/data directory?
    yes → persist only that directory（最优先）
    no
Is there a mutable subdirectory?
    yes → persist subdirectory only
    no
Same directory contains declarative + mutable files
    → mixed persistent container + declarative Home occupants
    （仅 app-private namespace；dual authority 非法；single-file
      bind 不是标准机制——详见 persistence.md（Mixed-authority））
```

## Secret ownership

```text
single app owner      → apps/<app>/secrets/*.age（definition 声明）
multiple consumers    → top-level secrets/shared/
machine/system        → top-level secrets/system/、secrets/hosts/<host>/；
                          machine identity/state → /persist/system（machine-state）
install/bootstrap     → top-level secrets/install/、secrets/bootstrap/
```

generic `security/secrets.scm` 只做机制（解密/发布/事务）——
不知道 repository layout，不知道具体 app/host。app-private source
用 source-relative `local-file`；top-level 集中 secrets 用唯一
resolver `(guixcfg utils repository-source)`。

## data-nobackup

`/persist/data-nobackup`（@persist-data-nobackup 子卷）：

- **persistent、bulk、reacquirable、direct-access** storage class；
- **不进入 app persistence bind registry**（不产生
  `/persist/data-nobackup/... → bind → HOME` 映射）；
- app 被**显式配置**去使用该路径（如 Steam Library path
  `/persist/data-nobackup/steam`）；
- 当前**没有 backup subsystem**；`nobackup` 只表示 storage intent。

## Runtime dependency invariant

```text
repository
    ↓ reconfigure/build
store / system generation
    ↓ runtime
```

**禁止**：

```text
runtime → repository checkout
```

例如：

```text
ExecStart=/home/foo/guix-configs/scripts/bar      ; 禁止
~/.config/foo -> ~/guix-configs/foo               ; 禁止（symlink 回 checkout）
```

`/persist/data-home/<user>/guix-configs` 可以**作为用户数据目录本身**
存在（用户自己维护的 checkout），但 runtime subsystem 不得因配置
执行而依赖它。
