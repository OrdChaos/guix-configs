# Application Layer（架构参考）

用户态配置的纵向组织单元。**How-to（新增应用）见
`docs/development/applications.md`**；开发约束摘要见 AGENT.md §12。

## Host-agnostic boundary（资源所有权 / variant selection）

```text
application
    │ 拥有配置资源 + 声明 logical configuration variants
    ▼
generic application composition
    │ 解析 selection → 校验 → 安装声明文件
    ▲
host/profile
    │ 只做 logical variant selection（application 名 + variant 名）
```

**Applications own their configuration resources and declare logical
configuration variants.**

- Application modules own their common configuration **and** their
  optional configuration variants (resources colocate in the
  application's own directory).
- Hosts/profiles select variants by application and logical variant
  name only.
- The generic application composition layer resolves selections into
  opaque configuration-file contributions.
- The application layer must not inspect host or hardware inventory.

```text
inventory  = facts
host/profile = policy / selection
application = resource ownership / application behavior
composition = resolution / assembly
```

inventory（如有）只描述事实；host/profile 依据这些事实做策略与
selection 决定；application 模块不得反向依赖 host。禁止 application
读取当前 host、判断 laptop/VM/GPU/display。

### configuration variants（`(guixcfg apps model)`）

application 声明可选配置变体——**application 拥有资源与声明**：

```scheme
(application-configuration-variant
 (name 'laptop)                    ; 稳定 logical identifier
 (files `(("niri/host.kdl"         ; 完整 ~/.config 相对 target
           ,(local-file "variants/laptop.kdl")))))  ; opaque file-like
```

```scheme
(application
 (name 'niri)
 ...
 (configuration-variants (list ...)))
```

- variant 是 application 自己声明的资源；source 文件 colocate 在
  application 自己的目录（如 `apps/niri/variants/laptop.kdl`）；
- `files` 是 `(target source)` 两元素列表的集合——一个 variant 可
  贡献多个文件；target 是完整 `~/.config` 相对路径（与 application
  name **无耦合**，不假设"应用名 = 配置目录名"）；source 是 opaque
  file-like，generic 层不解析格式。

### variant selection（`(guixcfg apps selection)`）

host/profile 只做 logical selection——**不知道文件、目标路径、
source 位置**：

```scheme
;; modules/guixcfg/hosts/laptop.scm
(define %laptop-application-configuration-selections
  (list (application-configuration-selection
         (application 'niri)
         (variant 'laptop))))
```

```scheme
;; modules/guixcfg/home/user.scm
(guix-home #:application-configuration-selections
           %laptop-application-configuration-selections)
```

`application-configuration-selections->home-services` 解析：
selection → lookup application（registry）→ lookup 声明 variant →
resolve files → 校验 target → 冲突检测 → 聚合为
`home-files-service-type` 的 native extension（target 加 `.config/`
前缀）。

**封装不变量**：改变 variant 背后的文件或目标路径（如
`niri/host.kdl` → `niri/device.kdl`，或一个文件拆成多个）**不需要
修改 host 的 selection**。

**冲突语义**：同一最终目标路径只能有一个 owner。

- resolver 在解析后按 target 查重，重复立即报错并列出冲突路径与
  全部来源（application + variant + source 描述，fail fast，无隐式
  顺序覆盖）；
- 跨贡献方冲突（如 variant 与 application 自身文件撞同一路径）由
  Guix Home 的 `assert-no-duplicates` 在 lower 时兜底报错（
  gnu/home/services.scm `files->files-directory`）——复用官方机制，
  不重复实现另一套冲突系统。

**不要把 variant 定义成 host/hardware 专用概念**：'laptop 只是
第一个实际 variant；API vocabulary 保持 application-generic
（未来可有 'compact-ui / 'accessibility 等）。

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
六个贡献字段 + 名字：

```scheme
(application
 (name 'foo)                 ; 唯一 logical name（registry 校验）
 (home-packages (list ...))  ; Home profile 显式安装的包
 (home-services (list ...))  ; home service 实例
 (system-services (list ...)) ; 仅少数确需 system-level service 的 app
 (persistence (list ...))    ; <application-persistence-rule>（声明，不实现挂载）
 (secrets (list ...))        ; <secret-decl>（声明，不实现解密）
 (gsettings (list ...)))     ; <gsettings-setting>（声明，不实现投影）
```

| 字段 | 语义 | 注意 |
|---|---|---|
| `name` | 唯一 logical application name | registry 加载时查重（fail fast） |
| `home-packages` | Home profile 显式安装的 package | **官方 Home service 自动贡献的包不重复声明**（home-niri 已带 niri/dbus/portal/xwayland-satellite，home-pipewire 已带 pipewire/wireplumber） |
| `home-services` | 优先顺序：1) official Home service；2) `simple-service` extension；3) generic Home/XDG file services | 禁止双 owner（同一能力两个 active 来源） |
| `system-services` | 仅少数真正需要 system-level service 的 app | **不要**用它包装 greetd/accounts/readiness/TPM/UKI/Secure Boot 等核心基础设施 |
| `persistence` | 声明 app-owned mutable canonical state | 只声明 rule，挂载由 `(guixcfg system application-persistence)` 执行 |
| `secrets` | 声明 app 需要的 ciphertext/runtime secret | 只声明，解密/发布由 `(guixcfg security secrets)` 执行 |
| `gsettings` | 声明 app 负责的静态 GSettings（schema/key/value，GVariant 文本） | 只声明，投影由 `(guixcfg gsettings …)` 执行到 runtime dconf；`(schema,key)` 全局单一 owner；appearance 6 键保留域不可声明（docs/architecture/gsettings.md） |

聚合（registry → Home/System）：

```scheme
(applications-home-packages %applications)
(applications-home-services %applications)
(applications-system-services %applications)
(applications-persistence %applications)
(applications-secrets %applications)
(applications-gsettings %applications)   ; ((owner . <gsettings-setting>) ...)
```

## Application service rule

Application unit 可以贡献 packages / Home services/extensions /
system services/extensions / persistence / secrets。但：

> **Applications do not merge Guix service values.**

共享 Home sink（`home-files`、environment variables 等——多个 app
都可能贡献的 target）必须经 Guix **native service-extension 机制**
贡献：

```scheme
(simple-service
 'mpv-config
 home-files-service-type
 `((".config/mpv/mpv.conf" ,(local-file "mpv.conf"))))
```

而不是：

```scheme
(service home-files-service-type ...)
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

system services 同理：官方单例 service 直接 `(service ...)` 放进
application 的 `system-services`（host assembly 经
`applications-system-services` 消费；当前没有 app 声明 system
services——PAM 扩展已从 keyring 移除，见
`architecture/desktop-authentication.md`）。

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

**前提：load path 必须绝对**。local-file 的目录解析延迟到 lowering
（`delay` + `current-source-directory`）才执行；load path 含相对条目
（`-L modules`）时解析退化为裸文件名、`canonicalize-path` 报
"No such file or directory"（实测 2026-08）。因此**一切构建/部署入口
的 `-L` 必须绝对**（`-L "$PWD/modules"` / `-L "$ROOT/modules"`；
tests 的 `add-to-load-path` 本来就拼绝对路径）。

`(guixcfg utils repository-source)` 的 `repository-file` 只用于
**仓库根相对资源**（如测试 sentinel `tests/fixtures/secrets/...`
由 VM 测试机装配引用——taxonomy 见 secrets.md），不替代 ordinary
模块内 source-relative `local-file`。

## Data ownership 决策表

| 数据 | 去向 |
|---|---|
| 可由 repo 确定性重建？ | → Guix Home / System（derived state） |
| 上游只提供滚动 URL、无固定版本地址的应用数据资源？ | → 上游/自建 channel 以版本化 snapshot release pin（先例：rime-data-wanxiang——tag = 快照时间戳，asset 按 tag immutable，fixed-output sha256 稳定；version 与 tag 同步升级） |
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
    （仅 app-private namespace；dual authority 非法；单文件状态用
      generic engine 的 bind-file exposure——只限【直写同一路径】
      的更新模型，temp+rename 原子替换的应用不适用——详见
      persistence.md（exposure 语义 / Mixed-authority））
```

## Secret ownership

```text
app 密文          → apps/<app>/secrets/*.age（definition 声明）
系统组件密文      → modules/guixcfg/<域>/<组件>/secrets/*.age
机制自身密钥      → modules/guixcfg/security/secrets/age/
install/recovery  → modules/guixcfg/security/secrets/、users/secrets/
测试 sentinel     → tests/fixtures/secrets/*.age
machine identity/state → /persist/system（machine-state）
（无 host 层——密文与引用者同置；taxonomy 见 secrets.md）
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
