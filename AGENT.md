# AGENT.md — 仓库开发规则（agent 与贡献者共同遵守）

本文件沉淀本项目在历次开发/排障中确立的强制规则。遇到新问题时先读这里，
再动手。

## 1. 构建安全（最高优先级）

- **Linux kernel 本地编译 = 异常**：本项目 kernel 是 Nonguix standard
  Linux（exact pinned derivation），官方 substitute 已证明存在。任何命令
  （build / test / repl probe）意外触发 `linux-7.1.8` 本地编译
  （cc1/make/vmlinux 进程树、sustained 高 CPU）→ **立即终止**：
  1. 识别进程树（顶层 client → daemon connection worker → builder）
  2. 终止 top-level client（我的进程）
  3. worker 属 guix-daemon 用户（root），我无权限时请用户以 root
     `systemctl restart guix-daemon`（受控重启清空构建队列）或精确 kill
  4. 诊断（URL？key？daemon？derivation 被改？缓存缺 exact build？）
  5. 修复后以安全方式重试
- 禁止 `pkill guix/make/cc1` 无差别杀；禁止杀 guix-daemon（除非证明无法
  恢复）；禁止 `guix gc` / 删 store / reboot 作为中止手段。
- **网络问题一律重试/轮询**：Guix 下载器对 GitHub release-assets 有 10
  秒超时，失败后 fallback 可能 404。遇到下载失败：直接重跑/轮询重试，
  不要发明替代方案（scp 拷 store、改 channel 等都属于禁止的绕过）。

## 2. Substitute / probe 方法

- **substitute availability 判断必须用 `guix build --dry-run`**（显式
  `--substitute-urls` 含 nonguix），**不要用 raw repl 的
  `(package-derivation ...)`**——graft 默认开启时它会因
  `non-self-references` 查询 output 而**真实触发 build**（已实测）。
- `guix build --dry-run` 安全是因为 CLI 注册了 build-handler（请求被
  累积不执行）。
- 大包（kernel、toolchain、浏览器类）dry-run 意外显示 `will be built`
  时先停止诊断，不默认编完。
- 首次 transition / fresh install：先 `guix archive --authorize
  < nonguix-key.pub` + 显式 `--substitute-urls`（见 installation.md
  阶段 4.5/5）。

## 3. Generated Guile runtime 规则（boot/login 关键路径）

- **program-file / gexp 生成独立 runtime 程序**：外层模块的 import 不会
  进入 generated runtime。`#~(begin ...)` 内使用的**每个非 Guile core
  binding 必须在 gexp 内显式 `(use-modules ...)`**（或不用它）。
  已发生同类事故：`delete-duplicates`（SRFI-1）、`string-join`/
  `string-split`/`string-null?`（SRFI-13）在 session launcher 中
  unbound。
- **login-critical bootstrap 保持最小**：优先纯 Guile core
  （string-append/string=?/member/…）；不为 dedup/拼接美观引入 SRFI/
  match 等 runtime 依赖。需要 helper 时定义为**单一 gexp**（注入 +
  测试执行同一 code path），不复制实现。
- **开机/登录关键路径的 generated Guile 程序必须有真实执行级 smoke
  test**：materialize 后实际 primitive-load 执行（如无 XDG_RUNTIME_DIR
  时应报预期错误而非 "Unbound variable"）。只检查 gexp 结构/字符串
  不算数——它们能全 PASS 而 primitive-load 仍炸。
- 每次新增 program-file/activation/initrd gexp 后，做 symbol audit：
  A（Guile core）/ B（gexp 内显式 import）/ C（gexp 注入的 store 对象）
  / D（意外外层 binding——**D 必须归零**）。

## 4. 测试规则

- 代码修改后跑：targeted test → 相关子系统 → 全量套件（
  `guix time-machine -C channels.lock.scm -- repl tests/run-tests.scm`）。
- 全量/构建型测试期间监控 kernel build（见 §1）。
- 不使用 VM 做代码验证，除非用户明确要求 runtime acceptance。
- 测试不得依赖公网实时可用性（substitute availability 是
  integration probe，不是 unit test）。

## 5. 安装/身份规则

- **阶段 5（安装 stable identity 到 persist）必须先于 system init**：
  漏装/后装导致首次 boot secrets-deploy 无法解密 →
  interactive-secrets-ready 失败 → login barrier 卡死（多次实测）。
- commit-root 会兜底自动安装（缺失且 /run identity 可用时），无
  runtime identity 则 fail-fast。
- 安装时 LUKS passphrase 经 `--luks-secret`（age 解密 luks-recovery.age，
  注意 decrypt 命令保留尾换行，cryptsetup 需要去换行）。
- **无人值守安装必须包含 Secure Boot 固件注册（阶段 9）**：keygen
  之后、关机之前，构建 keystore + sbkeysync 写固件（db/KEK 先，PK
  最后——写 PK 才退出 Setup Mode）。漏做则重启后固件仍在 Setup
  Mode，PCR7 enrollment preflight 失败（已实测一次；enroll 是
  单向的，VM 重置需重建 OVMF VARS 文件）。

## 6. Prior-art 强制审计（新增 infrastructure 前）

新增以下任何一类之前，必须先查 pinned source（不凭记忆/网上 master）：

- session manager / service wrapper / process launcher / persistence
  helper / package transform / login plumbing / desktop lifecycle /
  graphics integration / boot helper

回答顺序：
1. upstream 是否有正式机制？
2. **exact pinned Guix**（channels.lock.scm 的 revision）是否有
   service/type/helper？（检查 `~/.cache/guix/checkouts/<guix>/` 或
   store 中 pinned checkout）
3. Nonguix/Rosenthal/Virelith 等 pinned channel 是否已有？
4. 至少两个成熟 Guix 配置怎么用？
5. systemd/FHS-specific 与可迁移语义的区分
6. 我们的 invariant 是否真的要求 custom layer？

**pinned source 是唯一 API truth**：禁止为了新 API repin Guix/Nonguix/
channels；禁止照最新 master/博客写代码。

- **命名容易误导的 API 必须先读 exact upstream semantics，不能从
  字段名猜**：display manager / session manager / greeter 类尤甚。
  已实测教训（2026-08-18，commit 528fa92）：greetd 的
  `default_session` 语义是 **greeter**（"The default session, also
  known as the greeter."——greetd config.toml；server.rs
  greet()→start_greeter 以 default_session.user 无认证运行，
  authenticate=false），**不是**"认证后的默认桌面 session"；
  `initial_session` 只在 first-run 启动。把 greetd-user-session 直接
  放进 default-session-command = 把 bash -l 当 greeter 以 greeter
  用户运行——无登录提示符。正确模式：`greetd-agreety-session`
  包装 `greetd-user-session`（Guix 默认值/手册一致）。

## 7. Officialization 原则（use official, keep custom only where semantics differ）

- `use official mechanism where semantics match; custom code only owns
  project-specific semantics`。
- 判断标准（全部满足才 OFFICIALIZE）：pinned official API 存在；语义
  基本完全重叠；项目 invariant 不丢；state authority 不会变两个；
  runtime owner 不会重复；failure semantics 可接受；迁移后测试更简单。
- **KEEP（不官方化）**：persistence、root-generation（Normal/Recovery
  pair）、accounts（单一 writer projection）、secrets（root-owned age
  publisher）、readiness barrier（interactive-session-ready 等）、
  TPM/UKI/Secure Boot、custom initrd、atomic-file helper（含 parent
  fsync——官方 helper 无此语义）、spawn helper（static Guile 已验证
  问题）。
- **THIN ADAPTER**：readiness → greetd gate（官方 greetd 服务必须
  requirement 含 interactive-session-ready）；SSH persistent host-key；
  NVIDIA future adapter（disabled/identity）。
- **禁止双 owner**：custom dbus-run-session + home-dbus 不能同时 active；
  niri spawn pipewire + home-pipewire 禁止；xwayland-satellite 手工
  spawn + 官方自动管理禁止。source 可并存，active composition 只能
  一个 owner。
- 一个 bug 的修复如果开始表现为"给 custom wrapper 补 PATH/HOME/D-Bus/
  XDG/process lifecycle"，先停下重新问：这是否已有 upstream
  abstraction？

## 8. 架构分层（官方化 register 见 docs/architecture/upstream-boundaries.md）

- **PROJECT-SPECIFIC**：persistence、root-generation、accounts、
  secrets、readiness、TPM、UKI、Secure Boot
- **OFFICIAL GUIX**：authenticated user desktop lifecycle、Home
  D-Bus、Home Niri、Home PipeWire、Xwayland/portal（官方提供处）
- **THIN ADAPTER**：readiness→greetd、Home activation 验证、
  SSH persistent host-key、NVIDIA future adapter

## 9. 环境/机器规则

- 用户在意风扇噪音：构建并行度受控（测试里 `set-build-options
  #:build-cores` 按需设低值；避免 11 并行 cc1 满载）。
- 宿主 /gnu/store 只读挂载是设计（daemon 私有 namespace 可写）；
  store 内文件 chmod 会失败（只读）——测试不要 chmod store 产物
  （gexp->script 输出已可执行）。
- 后台任务经 zcode 管理，重启后可能恢复重跑——已完成的不会；被 kill
  的不要依赖其重跑。

## 10. Git / 工作树

- 不覆盖用户未提交修改；禁止 `git reset --hard` / `git clean -fd` /
  force checkout。
- 不提交临时文件（/tmp probe、debug 输出）、build-cores workaround
  （只为容忍意外 kernel 编译）、disable-grafts 生产代码。
- commit 按语义拆分（如 platform / guix / tests / desktop 分主题）。

## 11. UI 语言

- 项目拥有的 runtime CLI/TTY/installer/test 输出必须 English printable
  ASCII（无中文、Unicode 箭头、box-drawing、emoji）。注释/docstring/
  docs 可用中文。外部程序输出（Guix/cryptsetup/tpm2-tools 等）不翻译。
- test-ui-language.scm 静态+动态回归此规则。
