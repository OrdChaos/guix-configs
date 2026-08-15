# tpm2-enroll 已安装系统修复 — Final Report

## 1. Original Failure

在已安装（SecureBoot=1、SetupMode=0）的目标系统上：

- `preflight` 全 [ok]、0 项失败（假绿）；
- `enroll` 输入 recovery 密码后，读 PCR7 阶段失败：
  `guix repl: error: spawn: No such file or directory:
  "/run/current-system/profile/bin/tpm2_pcrread"`；
- `status` 显示「尚未 enrollment」；
- `replace` 报 `wrong number of arguments to
  #<procedure error (who message . irritants)>`（错误处理本身崩溃）。

## 2. TPM2 Executable Resolution Root Cause

`%tpm2-bin` 的解析链：

```scheme
(or (getenv "GUIXCFG_TPM2_BIN")
    (store-glob "tpm2-tools-" "/bin")        ; ← 前缀匹配
    "/run/current-system/profile/bin")       ; ← fallback
```

两个缺陷：

1. `store-glob` 用 `string-prefix? "tpm2-tools-"` 扫描 `/gnu/store`——
   真实条目名是 `<hash>-tpm2-tools-compat-5.8`（hash 在前），前缀
   永远匹配不到；且模糊扫描在多 generation/多版本/官方与 compat 并存
   时有选错风险。
2. fallback `/run/current-system/profile/bin` 里没有 tpm2 工具——
   `tpm2-tools-compat` 不在 system profile 中。

## 3. Actual tpm2-tools Store/Profile Path

`tpm2-tools-compat`（Virelith 5.8）此前只作为 initrd 闭包依赖存在于
store；system profile（`%system-packages` = btrfs-progs + cryptsetup +
%base-packages）没有它。`cryptsetup` 已在 profile（`/run/current-
system/profile/sbin/cryptsetup`），因此 cryptsetup 路径本来有效。

## 4. Fix Chosen

方案 A（用户首选）：把 `tpm2-tools-compat` **显式加入 vm system
profile**（与 T3 host 相同的模式），使
`/run/current-system/profile/bin/tpm2_pcrread` 成为真实、稳定的路径；
`%tpm2-bin` / `%cryptsetup` 改为确定性解析：

```scheme
(define %tpm2-bin (or (getenv "GUIXCFG_TPM2_BIN")      ; 仅测试/调试
                      "/run/current-system/profile/bin"))
(define %cryptsetup (or (getenv "GUIXCFG_CRYPTSETUP")  ; 仅测试/调试
                        "/run/current-system/profile/sbin/cryptsetup"))
```

## 5. Why /gnu/store Fuzzy Scanning Is/Is Not Used

不再使用。store 条目名 `<hash>-name-version` 的前缀匹配天然不可靠，
且扫描结果依赖 store 内容（多 generation、官方/兼容并存时歧义）。
依赖来源必须确定：锁定 Virelith 的 `tpm2-tools-compat` 经 system
profile 显式暴露，测试用 `GUIXCFG_TPM2_BIN` 覆盖（不进生产路径）。

## 6. Preflight Changes

preflight 现在验证 enrollment 真正需要的全部 executables：

```
cryptsetup + tpm2_pcrread / tpm2_policypcr / tpm2_createprimary /
tpm2_startauthsession / tpm2_create / tpm2_load / tpm2_unseal /
tpm2_flushcontext
```

每个检查 path exists + 可执行位（guile 核心 stat mode——`(guix build
utils)` 的 `file-executable?` 在 guix repl 未导出、`(ice-9 posix)` 在
time-machine repl 不可用，均实测）；失败输出
`[FAIL] <name> 可执行: <path>` 并**非零退出**。preflight 重构为可测的
`executable-checks` / `preflight-checks`。

## 7. error Binding Root Cause

`(rnrs base)` 全量导入覆盖了 Guile 原生 `error`——R6RS 签名
`(who message . irritants)` 与 Guile 的 `(error message . args)` 不同，
导致 `replace` 在未 enrollment 时 `(error "尚未 enrollment...")`
变成 wrong-number-of-arguments。

## 8. Namespace Fix

`(rnrs base)` 改为 selective import：`((rnrs base) #:select (let-values))`
——只取 unseal 管道回收需要的 `let-values`，Guile 原生 `error` 恢复
负责现有调用。全仓扫描（`(error ` in tools/tpm2-enroll.scm 与
tpm2 模块）确认无其他 `error` 覆盖。

## 9. Regression Tests

`tests/test-tpm2-enroll.scm`（A-D）：

- **A**：mock bin 目录齐全 → `executable-checks` 全通过
- **B**：删 tpm2_pcrread → 检查失败（preflight 不再假绿）
- **C**：未 enrollment 调 `do-replace` → 正常 misc-error（消息含
  「尚未 enrollment」），非 arity 错误
- **D**：tpm2-enroll.scm 可编译，无 unbound/wrong-import 警告

全套回归：260 expected passes，0 unexpected。

## 10. Installed-System Preflight

人工验证（VM，SecureBoot=1、SetupMode=0）：tpm 相关全部正常
（preflight 0 项失败、TPM 工具经 profile 可达）。

## 11. Enrollment Result

人工验证完成：enroll 完整成功（密码验证 → PCR7 读取 → credential
生成 → TPM seal → unseal 自检 → luksAddKey → ESP 发布 → state 发布）。

## 12. Status Result

`status` 显示已 enrollment。

## 13. LUKS Keyslots

`luksDump` 确认：recovery password slot 保留、TPM slot 新增。

## 14. Reboot Auto-Unlock Result

用户确认 tpm 相关一切正常（含重启自动解锁路径；Recovery 与密码
回退场景另见下节）。

## 15. Commit

- `adf23e4` fix(tpm2): resolve enrollment tools and preserve Guile error binding
- `d15e308` fix(boot): resolve recovery candidate system from deployed cmdline

## 16. Remaining Limitations

- TPM bootstrap-pending / first-boot service / 自动 enroll / 自动
  replace / PCR7 policy 修改：按计划 deferred（手工 enroll 已可用）。
- `tpm2-tools-compat` 加入的是 vm host profile；其他 host（laptop 等）
  如需 enroll 需各自显式加入（未在本次改动内）。

---

## 附带：Recovery 菜单缺失的 bug 与看法（人工验证中发现）

### Bug

limine 菜单从不出现 Recovery 项（即便确认启动后）。根因：
`uki.scm` 写 candidate.scm 时用 `(dirname (dirname current-kernel))`
推导 system identity——kernel 为 `<hash>-linux-libre-x/bzImage` 形态
时两次 dirname 退到 `/gnu/store`，candidate.system 永远不等于
`/run/current-system`，`promote-recovery!` 的 match 检查永远失败
（fail-closed 生效：只写 boot-state、跳过 artifact/菜单 promote）。
修复（`d15e308`）：从部署 cmdline 的 `gnu.system=` 解析（部署权威
路径），fallback 保留旧推导。

### 看法

1. **测试布局掩盖了生产差异**：T3 的 install-init 用
   `$SYSTEM/kernel/bzImage` 布局（两次 dirname 恰好正确），而生产
   boot-plan-kernel 是 linux 包路径（`<hash>-linux-libre-x/bzImage`）——
   相同代码在两种布局下行为不同，测试未暴露。教训：路径推导
   （dirname 次数）依赖布局假设，应使用部署流程的权威信息
   （cmdline 的 gnu.system）而非从 kernel 路径反推。
2. **更正规的长期方案**是给 `<boot-plan>` 显式携带 system 字段
   （部署时写入、promote 直接比较），避免字符串解析——但那是
   record 与所有构造点的改动，超出本轮 scope，记为后续项。
3. **fail-closed 设计本身工作正常**：candidate 不匹配时 promote 只
   跳过 artifact/菜单、仍记录 boot-state、绝不写无效 identity——
   这次 bug 的表现（菜单缺失而非错误 promote）正是该设计的预期行为。
