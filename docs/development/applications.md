# Adding an Application（完整教程）

架构/契约见 `docs/architecture/applications.md`；本文件是逐步操作
手册。**目标：不读 implementation source 也能新增一个应用。**

## 标准流程总览

```bash
cp -r templates/application modules/guixcfg/apps/foo
```

然后：

1. 修改 module identity；
2. 把 `%APP` 改成 `%foo`；
3. 公开配置直接放进 `apps/foo/`；
4. app-private 密文放 `apps/foo/secrets/`；
5. 填 `definition.scm`；
6. `apps/registry.scm` 显式 import + 加入 `%applications`；
7. targeted tests → module load → full suite → reconfigure。

## E1. Module identity

```scheme
(define-module (guixcfg apps foo definition)
  ...)
```

导出 `%foo`（应用 record）。名字必须与 registry 中其它应用唯一。

## E2. 只有 package

最小例子：

```scheme
;;; foo application unit：CLI 工具。
(define-module (guixcfg apps foo definition)
               #:use-module (gnu packages foo) ; foo
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%foo))

(define %foo
  (application
   (name 'foo)
   (home-packages (list foo))))
```

## E3. package + config

```text
apps/foo/
├── definition.scm
└── config.toml
```

```scheme
(define %foo
  (application
   (name 'foo)
   (home-packages (list foo))
   (home-services
    (list (simple-service 'foo-config
                          home-files-service-type
                          `((".config/foo/config.toml"
                             ,(local-file "config.toml"))))))))
```

`(local-file "config.toml")` 按 **definition 所在目录**解析（pinned
Guix 语义）——不需要 `../../../files/...`，不依赖 shell CWD。
需要 `#:use-module (guix gexp)`（local-file）与
`#:use-module (gnu home services)`。

**共享 sink 用 extension，不用完整实例**：多个 app 都可能贡献
`home-files` 等 target——每个 app
用 `simple-service` 贡献 extension value（canonical target 由
Guix 自动实例化）；**不要** `(service home-files-service-type ...)`
创建第二个完整实例（ambiguous-target-service）。
唯一类型的独立 service（如 `home-niri-service-type`）保持直接
`(service ...)`。aggregator 只 concatenation，不做 same-kind
merge（`service-type-extend` 不是 base-value merger）。

**文件归属 service 选择规则**（2026-08 规则反转）：pinned Guix 已把
`home-xdg-configuration-files-service-type` 标记 deprecated（其语义
本就是 `home-files-service-type` 的 `.config/` 前缀包装）——仓库
**全部统一走 `home-files-service-type`**：

- `~/.config` 下的文件：target 显式写 `.config/` 前缀（如
  `.config/mpv/mpv.conf`）；
- XDG 约定覆盖不到的 HOME dotfile（`.ssh/*`、`.gitconfig`、
  `.local/bin/*` 等）：target 写 HOME 相对路径（如 `.gitconfig`）。

同一通道、无特化层、无交叉；`.config` 只是普通前缀。现有先例：全部
app（ghostty/niri/mpv/noctalia/fcitx5/gtk/vscode/nushell/starship/
gnupg 等）统一 home-files；variant selection（apps/selection.scm）
解析时加 `.config/` 前缀。variant/selection 机制（E9）因此也只落
`~/.config`：需要 per-host 的 `.ssh/*` 或 `.gitconfig` 变体时是已知
边界，须先扩展 selection resolver。

## E4. Official Home service

如果 pinned Guix 已提供官方 Home service，**优先使用**：

```scheme
(service home-foo-service-type ...)   ; 官方
```

不要同时手写同一配置（例如 custom wrapper + 官方 service）——
double authority 是架构违规（AGENT.md §12）。官方 service 自动贡献
的 package **不要**再写进 `home-packages`。

## E5. Mutable state（persistence）

应用产生的、需要跨 boot 保留的 mutable state：

```scheme
(persistence
 (list (application-persistence-rule
        (name 'state)
        (backing "foo")                ; /persist/data-app 相对
        (consumer ".local/share/foo")  ; HOME 相对
        (exposure 'bind-directory)
        (lifecycle 'application-owned))))
```

- `backing` 是 `/persist/data-app` **相对**路径；
- `consumer` 是 **HOME 相对**路径（generic executor 用 user 参数解析）；
- **不要**写 `/home/<user>/...` 绝对路径；
- consumer 不得是 `.config`/`.local`/`.local/share`/`.cache` 整体
  （其下子目录合法）；
- 挂载/目录创建由 `(guixcfg system application-persistence)` 执行，
  app 只声明。

**State 决策树**（mutable state 的持久化选择；架构详见
`docs/architecture/persistence.md`（Mixed-authority state container））：

```text
Does the application have mutable state?
    no  → Home config only（无需 persistence rule）
    yes
Does the repo need to provide the initial state?
    yes → persistence rule + seeds（seed-once：首次初始化后 repo
          永久放弃 ownership；如 Noctalia settings.toml）
    no
Can state live in separate state/data directory?
    yes → persist only that directory（最优先；如
          .config/foo repo + .local/state/foo app → 只持久化后者）
    no
Is there a mutable subdirectory?
    yes → persist subdirectory only（如 .config/foo/state）
    no
Same directory contains declarative + mutable files
    → mixed persistent container + declarative Home occupants
```

规则：**single-file persistence 不是首选方案**（应用 write-temp→
fsync→rename 原子替换会破坏单文件 bind/symlink）；mixed container
只允许 app-private namespace；**dual authority 是错误**（repo/Home
与应用不得同时写同一文件——选择 repo-owned 或 app-owned，不
merge，无 conflict-resolution framework）。

**seed-once 规则**：`seeds` 只声明"从未存在过的初始状态"（`(target
source)` 列表，source 为 app 目录 colocate 的 file-like）；机制
在 `(guixcfg utils seed-once)` + application persistence activation
（`docs/architecture/persistence.md`（seed-once））。seed 写入后
**repository 永久放弃该文件 ownership**——后续 reconfigure / seed
源更新都不得覆盖、同步或修正已初始化目标。**seed-once !=
declarative management**：不要把它改写成"每次同步默认配置"。

```scheme
(persistence
 (list (application-persistence-rule
        (name 'state)
        (backing "foo/state")
        (consumer ".local/state/foo")
        (exposure 'bind-directory)
        (lifecycle 'application-owned)
        (seeds `(("settings.toml"
                  ,(local-file "base-settings.toml")))))))
```

## Production example：MPV（第一个真实 consumer）

`modules/guixcfg/apps/mpv/`（pinned mpv 0.41.0）：

- declarative config 与 mutable state **天然分离**（decision tree 的
  Preferred 1）：
  - `~/.config/mpv/{mpv.conf,input.conf}` — repo/Home authority
    （source-relative local-file colocate）；
  - `~/.local/state/mpv/`（XDG_STATE_HOME；watch-later 默认
    `~/.local/state/mpv/watch_later`）— application authority；
- persistence rule：`backing "mpv/state"` →
  `consumer ".local/state/mpv"`（只持久化最小 app-private state
  目录；不持久化 `.config/mpv`、不持久化整个 `.local/state`）；
- `save-position-on-quit=yes` 启用 resume（watch-later）。

对比：**Fish**（未来 mixed-authority example）——declarative
（config.fish）与 mutable（fish_variables）共享一个 app-private
目录 → 需要 mixed persistent container（本任务不加入 Fish）。

MPV 验收步骤（docs 外，report B9）：reconfigure → `mpv --version` →
检查 `~/.config/mpv/*` 来自 Home generation → `findmnt` 确认
`~/.local/state/mpv` 是 `/persist/data-app/...` 的 bind → 播放到
明显时间点退出 → watch_later 文件出现 → reboot → 重新打开同一文件
resume 生效 → 未持久化的普通 HOME 临时文件 reboot 后消失。

需要 `#:use-module (guixcfg system application-persistence)`。

## E6. App-private secret

```text
apps/foo/secrets/token.age
```

```scheme
(secrets
 (list (secret-decl
        (name 'token)
        (scope 'user)                  ; 或 'system
        (source (local-file "secrets/token.age"))  ; source-relative
        (target-name "token")
        (owner-user "user")            ; runtime owner
        (mode #o600))))
```

- source 是 **file-like**（app-local `local-file`；top-level 集中
  secrets 用 `(guixcfg utils repository-source)` 的 `repository-file`）；
- 解密/发布由 generic `(guixcfg security secrets)` 执行；
- ciphertext 可以进 store；plaintext 只进 `/run`。

需要 `#:use-module (guixcfg security secrets)`（secret-decl）。

## E7. System service

仅当应用确实需要 system-level service（如未来 daemon）：

```scheme
(system-services (list (service ...)))
```

**不要**用它包装 greetd/accounts/readiness/TPM/UKI/Secure Boot 等
核心基础设施——那些有明确的 system-level ownership
（`docs/architecture/upstream-boundaries.md`）。

## E8. Registry（启用）

```scheme
;; apps/registry.scm
#:use-module (guixcfg apps foo definition)
...
(define %applications
  (list ... %foo ...))
```

> **directory exists does not enable the app.**
> 目录存在 ≠ 应用启用——启用必须经显式 registry。

registry 加载时校验名字唯一（重复直接报错）。

## E9. 可选配置变体与 logical selection（configuration variants）

应用层不知道"当前是哪台主机"（applications.md（Host-agnostic
boundary））。application 拥有自己的配置资源与可选配置变体声明；
host/profile 层只做 **logical selection**（application 名 +
variant 名），不知道文件、目标路径或 source 位置。

**第一步：application 声明 variant（资源 colocate 应用目录）**

```scheme
;; apps/foo/definition.scm（variants/ 下放原生配置文件）
(application
 (name 'foo)
 ...
 (configuration-variants
  (list (application-configuration-variant
         (name 'laptop)
         (files `(("foo/device.conf"     ; 完整 ~/.config 相对 target
                   ,(local-file "variants/laptop.conf"))))))))
```

**第二步：host 只做 selection**

```scheme
;; modules/guixcfg/hosts/<host>.scm
(define %host-application-configuration-selections
  (list (application-configuration-selection
         (application 'foo)
         (variant 'laptop))))
```

host 组装 home 时传入：

```scheme
(guix-home #:application-configuration-selections
           %host-application-configuration-selections)
```

机制语义（`(guixcfg apps selection)` +
`(guixcfg apps model)` 的 variant 声明）：

- target 原样作为目标路径经 `home-files-service-type` 以
  `~/.config/<target>` 安装（解析时加 `.config/` 前缀）；与
  application name 无耦合（不假设 "应用名 = 配置目录名"）；
- source 文件保持原生格式（KDL/TOML/...），Scheme 不解析内容；
- application（owner）必须已启用（registry 校验，fail fast）；
- variant 必须由该 application 声明（错误消息含 application +
  variant，fail fast）；
- 同一最终 target path 只能有一个 owner——重复立即报错（跨贡献方
  冲突由 Guix Home lower 时兜底）；
- **封装不变量**：改变 variant 背后的文件或目标路径不需要修改
  host 的 selection；
- 无 selection 的机器（VM）用默认 `%guix-home`——应用侧配置把
  可选文件做成 optional include（niri 26.04 支持 `optional=true`）。

## E10. Validation

应用层没有 per-app 测试（配置内容/应用列表不做断言——加应用不应
要求改测试）。框架级测试（application model、module compile、
assembly）自动覆盖新增 app：

```bash
# 全量（模块清单自动发现 + 拓扑排序，无需登记）
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
```

需要时 `blue reconfigure <host>`（Guile transaction，见
`operations/reconfigure.md`）；kernel 构建安全
规则见 AGENT.md §1（任何意外 `linux-*` 本地编译立即中止诊断）。
