# Testing

测试层级与各层能证明什么。

## Level 1 — Pure functions

`tests/test-*.scm` 中纯模型/纯函数的单元测试（storage model、root
generation 状态机、policies、plan、validate、users 等）。

证明：纯逻辑正确性。

不证明：任何 runtime 行为。

## Level 2 — Module load

`tests/test-modules-load.scm` 等：确认模块可加载、`%vm-os` 可实例化
（machine facts 由 run-tests.scm 注入测试值）。

证明：模块结构/依赖图健康，无 compile/load 错误。

不证明：generated runtime program 可执行。

## Level 3 — Generated artifact execution

`tests/test-runtime-exec.scm`：真正 `lower-object` 构建 generated
artifact（program-file / activation gexp），在隔离 root（user
namespace + chroot + bind `/gnu/store`）里执行，验证 exit code 与
最终可观察结果。覆盖 account databases projection、readiness start
thunk、secrets deploy、只读 verify。

证明：runtime module closure 完整、无 unbound-variable；fail-closed
语义真实生效；最终文件正确。

不证明：整机 boot 时序。

## Level 4 — System build

```bash
GUIX_CONFIG_FACTS=<facts> \
  guix time-machine -C channels.lock.scm -- system build \
  -L "$PWD/modules" -e '(@ (guixcfg hosts vm) %vm-os)'
```

证明：完整 OS 可构建，所有 activation/shepherd 配置生成正确。

不证明：构建出的系统能启动。

## Level 5 — QEMU fresh install / boot

`tools/test-vm.sh` + 串口/SSH 自动化：fresh install → boot → login。

证明：端到端（安装、UKI/Secure Boot、initrd、readiness、login）。

不证明：……不需要，这就是最终证明。

验收标准：fresh install 后的 **core baseline acceptance
checklist**（root generation state、/run/user/<uid> 生命周期、
Guix Home links、persistent bind mounts、shadow verifier、
失败 readiness boot 不 promote Last Good、第二次冷启动复查）
见 `operations/vm-testing.md`（Fresh install core baseline
acceptance checklist）。

## 标准命令

```bash
# full tests（pinned Guix）
guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm

# Blue 入口（等价，builtin check 经 repository-tests testable 薄包装
# 上面的 runner；测试清单的事实源仍是 run-tests.scm）
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/development.scm -- blue check

# blue -n check 不真正运行测试套件（Blue testable 的 builtin dry-run
# 语义，有意为之：全量套件可能触发 kernel 本地编译）

# system build dry-run / build
GUIX_CONFIG_FACTS=/tmp/facts.scm \
  guix time-machine -C channels.lock.scm -- system build \
  -L "$PWD/modules" -e '(@ (guixcfg hosts vm) %vm-os)'
```

不要把 "gexp successfully builds" 当作 "runtime program definitely
works"——Level 3 才证明后者。

## Substitute availability 的正确 probe 方式

判断“某个 package 有无 binary substitute”，**必须用
`guix build --dry-run`**，不要用 raw repl 里的
`(package-derivation ...)`：

```bash
guix time-machine -C channels.lock.scm -- build --dry-run \
  -L "$PWD/modules" \
  -e '(@ (guixcfg system kernel-platform) %kernel)'
```

注意：第三方 substitute（substitutes.nonguix.org）已移除
（2026-08-25）——nonguix 包（kernel/firmware/microcode）没有
substitute，dry-run 对它们总是显示 `would be built`；输出 store
路径 = 产物已在本地 store（缓存），否则需要本地编译。

**为什么 raw `(package-derivation %store PKG)` 不安全**（pinned
Guix 94a84f9 实测，graft A/B probe）：graft 默认开启（`%graft?`）时，
`package->derivation` 走 `bag-grafts` → 对依赖中带 replacement 的
包（如 glibc/gcc）收集 grafts → `graft-derivation*` →
`non-self-references` 查询 PKG output 的 runtime references →
output 不在 store 时 **`build-derivations` 被真实执行**（
guix/grafts.scm：guard 捕获 store-protocol-error 后 build）。
`guix build --dry-run` 安全是因为 CLI 注册了 build-handler
（`call-with-build-handler`），把 build 请求累积而不执行。

**结论**：raw repl + `package-derivation` 不是 substitute
availability probe；结构性单测如需避免无意 realize 大包，可在
明确的测试边界用 `#:graft? #f`（production configuration 保持
默认 graft 语义）。

## 昂贵构建预检

对于设计上预期由 substitute 提供的昂贵包（Linux kernel、大
toolchain、WebKit/Chromium 类），如果 dry-run 意外显示
`will be built locally`，**先停止并诊断**，不要默认让昂贵构建
完成：

```bash
# 例：exact selected kernel 的 substitute-aware dry-run
guix time-machine -C channels.lock.scm -- build --dry-run \
  -L "$PWD/modules" -e '(@ (guixcfg system kernel-platform) %kernel)'
```

这不是宣称“大包必须有 substitute”；语义是：**预期有 substitute
却缺失 → 先调查（URL？signing key？current daemon？derivation 被
修改？官方缓存缺 exact build？）再花昂贵构建时间**。首次迁移/
fresh install 的 bootstrap 步骤见
`operations/installation.md`（阶段 4.5）。
