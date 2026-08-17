# Testing

测试层级与各层能证明什么。

## Level 1 — Pure functions

`tests/test-*.scm` 中纯模型/纯函数的单元测试（storage model、root
generation 状态机、policies、plan、validate、users 等）。

证明：纯逻辑正确性。

不证明：任何 runtime 行为。

## Level 2 — Module load

`tests/test-modules-load.scm` 等：确认模块可加载、`%os` 可实例化
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
  -L modules -e '(@ (guixcfg hosts vm) %os)'
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

# system build dry-run / build
GUIX_CONFIG_FACTS=/tmp/facts.scm \
  guix time-machine -C channels.lock.scm -- system build \
  -L modules -e '(@ (guixcfg hosts vm) %os)'
```

不要把 "gexp successfully builds" 当作 "runtime program definitely
works"——Level 3 才证明后者。
