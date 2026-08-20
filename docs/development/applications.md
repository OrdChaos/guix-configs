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
    (list (simple-service 'foo-xdg-config
                          home-xdg-configuration-files-service-type
                          `(("foo/config.toml"
                             ,(local-file "config.toml"))))))))
```

`(local-file "config.toml")` 按 **definition 所在目录**解析（pinned
Guix 语义）——不需要 `../../../files/...`，不依赖 shell CWD。
需要 `#:use-module (guix gexp)`（local-file）与
`#:use-module (gnu home services)`。

**共享 sink 用 extension，不用完整实例**：多个 app 都可能贡献
`home-xdg-configuration-files` / `home-files` 等 target——每个 app
用 `simple-service` 贡献 extension value（canonical target 由
Guix 自动实例化）；**不要** `(service home-xdg-configuration-files-
service-type ...)` 创建第二个完整实例（ambiguous-target-service）。
唯一类型的独立 service（如 `home-niri-service-type`）保持直接
`(service ...)`。aggregator 只 concatenation，不做 same-kind
merge（`service-type-extend` 不是 base-value merger）。

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

## E9. Validation

应用层没有 per-app 测试（配置内容/应用列表不做断言——加应用不应
要求改测试）。框架级测试（application model、module compile、
assembly）自动覆盖新增 app：

```bash
# 全量（模块清单自动发现 + 拓扑排序，无需登记）
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm
```

需要时 system reconfigure（`tools/reconfigure.sh`）；kernel 构建安全
规则见 AGENT.md §1（任何意外 `linux-*` 本地编译立即中止诊断）。
