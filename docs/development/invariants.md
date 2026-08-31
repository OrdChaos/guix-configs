# Project Invariants

本文件是项目不可违背的设计不变量。任何新实现、重构都必须满足以下
规则；违反不变量本身就是 review blocker。

## 1. One fact, one authoritative definition

项目事实（路径、mapper 名、子卷名、用户名、readiness capability 名、
状态 schema）只在一个地方定义（通常 `guixcfg/storage/model.scm` 或
对应领域的 model 模块），其它地方引用它。禁止裸字符串重复散落。

## 2. One mutable runtime resource, one authoritative writer

每个 mutable runtime 资源（`/etc/{passwd,group,shadow}`、root
generation state、boot state、active UKI slot、SSH host keys、secrets
generation pointer、login gate）有且只有一个 authoritative writer。
发现第二 writer 时从设计上消除重复 ownership，而不是用 ordering 排队。

## 3. Persistent mutable state has one canonical backing object

每一份 mutable persistent data 只在持久层存在一个 canonical backing
object。应用路径通过 bind mount / symlink / direct reference 访问同一
backing object。禁止 boot copy → ephemeral / shutdown copy → persistent
的双副本同步模型。

## 4. Derived / reconstructible state is not persisted

Guix Home 生成物、UKI/build artifacts、可重建的 cache/index 属于
derived state，不进入 `/persist`。

## 5. Runtime generated code declares dependencies explicitly

boot-critical generated runtime program（gexp / program-file /
shepherd start thunk）必须显式声明其 runtime 模块依赖。禁止依赖
"外层 Scheme module 已 import"或"某模块 transitively depends on X"。

## 6. Runtime imports and generated module closure must agree

generated program 的 runtime `use-modules` 与 `source-module-closure`
seeds 必须一一对应：runtime 用到的非 Guile-core 模块显式出现在
closure seeds 中。可一眼审计。

## 7. Important state transitions are atomic

root generation state、boot state、account DB、secrets generation
pointer 等重要 mutable state 的更新必须原子（write temp → validate →
chmod/chown → fsync → rename）。使用共享 atomic 原语
（`guixcfg/utils/atomic-file.scm`）；目录级复合事务（ESP/UKI slot、
secrets generation）可以有各自专门的 transaction abstraction。

## 8. Readiness names capabilities

readiness capability 命名描述能力（`persistent-state-ready`、
`account-state-ready`、`home-ready`、`session-infra-ready`、
`interactive-session-ready`），不描述实现步骤（禁止
`did-copy-file-ready` 这类名字）。

## 9. Readiness is provisioned only after validating final state

login/boot-critical readiness 必须：执行操作 → 验证最终可观察结果 →
才 provision。禁止 "child spawned → immediately ready" 或
"operation attempted → ready"。

## 10. Project fixed facts / host policies / discovered facts are distinct

配置值分三类，放在对应层：

- **Project fixed fact**（路径、schema、capability 名）→ model 常量；
- **Host policy**（swap 大小、桌面 profile、固件选择、hostname）→
  `<host-storage-policy>` 等 policy record，host 组装点提供实例；
- **Discovered fact**（LUKS UUID、硬件标识）→ 安装时探测写入 facts
  文件。

VM 假设不得泄漏进 common 模块。

## 11. New persistent state must define its full contract

新增任何 persistent state 必须明确：canonical backing、consumer
path、exposure method（bind/symlink/direct/projection）、owner、
lifecycle。**backup 是未来独立 concern**——contract 不要求 backup
class，当前不制造 backup taxonomy。

应用 persistence（`/persist/data-app`）：generic engine 已实现
（`system/application-persistence.scm`，bind-directory / bind-file
两种 exposure——bind-file 只限【直写同一路径】的单文件状态；
严格 path validation、activation 恢复 consumer parent ownership）；
新增 production rule 必须走 `<application-persistence-rule>` 并满足
persistence contract 全部字段。

## 12. Composite runtime DBs may be projections

`/etc/{passwd,group,shadow}` 与 `/run/guixcfg-secrets*` 是合法的
projection exceptions：由 generation topology + persistent credential
（或 ciphertext + identity）合成，不违反 no-copy 原则。projection
必须是显式例外，不允许悄悄扩展。

## 13. Second-implementation trigger

当同一类行为准备出现第二种实现时（第二个 atomic state writer、第二个
subprocess capture helper、第二个 persistence deployment mechanism、
第二个 generated runtime module loader、第二个 account DB writer），
必须先判断是否需要公共 abstraction。第二套实现是 review trigger。

## 14. Repeated-bug trigger

同类 bug 第一次：local fix；第二次：category-wide audit。例如
`every`/`any` unbound 之后审计了所有 generated runtime dependencies。

## 附录：设计原则（历史沉淀）

1. 固定架构直接写进算法，不伪装成通用配置。
2. 所有长期状态 Btrfs 子卷都必须使用 `@persist-` 前缀。
3. 除标准 `/gnu/store` 和 `/var/guix` 外，持久化顶级挂载点统一位于
   `/persist`。
4. Root generation 使用 `@root-*`，因为它不是长期状态目录。
5. Host 是最终 `<operating-system>` 的组装点。
6. 共享模块不反向依赖 host。
7. 配置工作区不是正常启动依赖。
8. 公开配置进入 `/gnu/store`。
9. age 密文进入 Git 和 store，明文只进入 `/run`。
10. 机器 identity 位于 `/persist/system`。
11. 可变应用状态位于 `/persist/data-app`（bind projection；禁止整
    `.config`/`.local`/`.local/share`/`.cache` 持久化）。
12. 普通用户数据位于 `/persist/data-home`。
13. `/persist/data-nobackup` 是 persistent bulk/reacquirable、
    显式寻址的 storage class（direct access，不参加 app persistence
    bind registry）；当前无 backup subsystem。
14. 不把配置仓库直接软链接到应用运行路径。
15. 不在开机时复制一份仓库配置到持久目录。
16. 正式部署只消费已提交 Git commit 的只读快照。
17. 频道更新和系统部署严格分离。
18. Flatpak 是用户桌面层，不是仓库根级软件子系统。
19. Flatpak 默认只补齐，不自动删除。
20. Rust 多版本由项目 manifest 和频道锁管理，不使用 rustup。
21. `configctl` 是独立 Rust 部署工具，不解析 Scheme。
22. `mihomo-remote` 是独立 Rust 控制工具。
23. 先完成 VM，再适配 Laptop。
24. 在真实重复出现之后再进行抽象。
25. 少量明确重复优于维护一个自制的 NixOS module system。
26. 配置仓库随用户数据持久化，不单独拆分子卷。
27. 驱动通过 kernel、firmware、module 和 service 声明进入 system
    generation，不使用独立安装器。
28. 打印机队列声明式创建，不持久化 CUPS 命令式状态。
29. 自定义 record 使用 `(guix records)` 的 `define-record-type*`
    （具名字段、`default`、`inherit`），不使用裸 SRFI-9。
