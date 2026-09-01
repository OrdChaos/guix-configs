# Implementation Conventions

容易导致架构漂移的实现约定。不是完整 style guide；Scheme 排版遵循
仓库当前一致风格即可。

## Module layout

- `modules/guixcfg/<area>/<name>.scm`，area 按职责：
  `apps`（Application layer：`<application>` 纵向配置单元——model、
  registry、每个应用一个 `<app>/definition.scm` 目录）、`storage`
  （磁盘/子卷/generation 纯模型与安装器）、`boot`（initrd/UKI/TPM
  解锁）、`system`（OS 组装、readiness、accounts、ssh、
  user-persistence、application-persistence）、`security`
  （age/secrets/证书）、`services`（用户态 one-shot 服务）、`home`
  （Guix Home 薄入口）、`users`（用户结构事实）、`utils`（跨领域
  原语，含 repository-source 唯一 resolver）。
- 一个模块一句清晰职责描述（文件头注释）。
- pure model（storage/root-generation、boot/boot-state 的读写分离）
  与 executor/service/tool 分开；model 不 mount/delete/spawn。
- host-owned inventory（如 `%vm-test-secrets`，hosts/vm.scm 内的
  测试 sentinel）放 host 模块附近，不混入 generic mechanism。

## Exports

- `#:export` 只列对外契约；模块内部 helper 不导出。
- 命名：`%` 前缀 = 常量/parameter；`<name>` = record type；
  `name?` = predicate；`*-program` = program-file 生成器；
  `*-service` = service 构造器；`*-gexp` = gexp 生成器；
  `*-path` = 路径常量；`*-ready` = readiness capability。

## Generated runtime pattern

- 简单 boot-critical thunk：只使用 Guile core（`and`/`file-exists?`
  等），不引入模块依赖。
- 复杂 runtime program：`program-file` + `with-imported-modules` +
  `source-module-closure`，runtime `use-modules` 与 closure seeds
  一一对应（见 invariants 5/6）。
- SRFI/ice-9/guix build utils 允许正常使用；问题是 undeclared
  dependency，不是 SRFI 本身。
- 测试必须真实执行 generated artifact（见 development/testing.md）。

## Subprocess abstraction

- `guixcfg/utils/process`：popen-based，host/runtime（非 initrd）——
  文本/字节 stdin 注入（`invoke-with-stdin` 系列）与 stdout 捕获
  （`invoke-capture` 系列）；非零退出码抛错。
- `guixcfg/utils/spawn`：posix_spawn-based，initrd/static-Guile 专用
  （PID1 下 fork/popen 有 GC 故障）；显式绝对路径。
- 直接 `invoke`/`system*` 允许：无 stdin/stdout 定制需求、错误语义
  由调用方处理的场景。

## Atomic update

- 单文件 state：`guixcfg/utils/atomic-file` 的
  `atomic-write-file!` / `atomic-replace-file!`。
- 目录/复合事务（UKI slot、secrets generation）：各自专门的
  transaction abstraction（`.new` staging → rename → symlink switch），
  保持单 owner。
- 禁止为"看起来统一"把目录事务硬套单文件原语。

## Error semantics

- Programmer invariant violation / boot-critical failure：`(error ...)`
  ——可诊断、含上下文（路径/用户）。
- Expected operational failure：显式检查 + 明确报错/退出码。
- Optional/noncritical failure：`false-if-exception` 或条件检查。
- Cleanup 路径可用 `catch`/`false-if-exception`，不得掩盖主错误。
- 不要所有错误都 `(catch #t ...)`；boot-critical 失败必须可诊断。

## Service / readiness naming

- service provision 名：实现名（`guixcfg-...`）+ capability
  （`account-state-ready` 等）。
- readiness 命名 capability，不命名实现步骤。
- fail-closed：execute → validate final state → provision。

## Constants / model placement

- Project fixed facts 放 model 常量（`storage/model.scm` 等）。
- Host policy 放 `<host-storage-policy>` 等 record，实例在
  `storage/policies.scm`；host 模块 re-export。
- 模块内局部路径常量（如 `%persist-system-mount`）放使用模块，
  不强行 DRY。

## Comments

- 注释解释 why / invariant / non-obvious Guix/runtime 行为，不解释
  下一行在做什么。
- 长篇架构说明迁入 docs，源码只留简短 rationale + doc link。
