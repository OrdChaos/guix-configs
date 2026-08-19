# Architecture Overview

30 分钟理解整个系统的入口。实现细节在各主题文档。

## 系统生命周期

```text
repo + locked channels（channels.lock.scm）
    |
    v
system generation（guix system init/reconfigure）
    |
    v
UKI / Secure Boot（ESP，A/B 槽 + Recovery）
    |
    v
initrd（LUKS 解锁：TPM PCR7 或密码）
    |
    v
root generation（@root-N 选择/创建）
    |
    v
persistent mounts（/persist/* 子卷、/var/guix、/gnu/store）
    |
    v
activation（account databases、host keys、secrets、user dirs）
    |
    v
readiness DAG（persistent-state → account/secrets → home/session → interactive）
    |
    v
login / session / Guix Home
```

## 核心概念

### persistent vs derived

- **persistent**：`/persist/*` 内的 canonical backing（系统状态、用户
  数据、credential verifier），跨 generation 保留。
- **derived**：Guix Home 生成物、UKI/build artifacts、可重建的
  cache/index。不持久化。

不变量：persistent mutable state 只有一个 canonical backing；
runtime 路径通过 bind/symlink/direct reference 访问它。详见
`architecture/persistence.md`。

### root / system / Home generation 关系

- **root generation**（`@root-N`，Btrfs 子卷）：无状态根，每次 boot
  由 initrd 按 state 选择/创建。`@root-template` 只读模板，
  `@root-0` 首次提交。
- **system generation**（`/var/guix/profiles/system`）：Guix system
  声明，bootloader/UKI 由此生成。两轴正交（root 轴管理 Btrfs
  回退，system 轴管理 Guix generation 回退）。
- **Guix Home**：随 system generation 构建，activate 时投影到
  ephemeral `$HOME`。没有独立的 Home generation 轴。

### Security boundary

公开仓库可含 recipient、ciphertext、passphrase 加密的 identity；
不得含明文密码、明文 private identity、直接暴露的 login verifier、
明文 runtime secrets。已解锁本机的 root 明确在防御范围之外。
详见 `architecture/secrets.md`。

### Service readiness model

boot 按 capability DAG 推进：

```text
file-systems → persistent-state-ready
  → {account-state-ready（account DB 投影 + 只读验证）∥ interactive-secrets-ready}
  → {home-ready ∥ session-infra-ready（elogind）}
  → interactive-session-ready → 打开 login gate → login
```

readiness 命名 capability；provision 前必须验证最终可观察状态
（fail-closed）。详见 `architecture/accounts-sessions.md`。

## 软件分类

不能建立宣称包含"全部软件"的根级 `software/` 目录；软件按生命周期
分类：

- **系统级 Guix 软件**：`modules/guixcfg/system/packages.scm`
  （configctl、flatpak、文件系统/恢复/硬件工具、所有用户需要的基础
  工具）。服务自己依赖的软件尽量由 service 直接引用。
- **用户级 Guix 软件**：`modules/guixcfg/apps/<name>/definition.scm`
  （application layer——纵向配置单元；home packages/services 经
  `apps/registry.scm` 聚合进 `%guix-home`）。见 `architecture/home.md`
  的 Application layer 一节。
- **项目专属工具链**：项目自身（manifest、channels.lock.scm），
  不放进全局用户软件列表。

## 阅读顺序

1. `architecture/storage.md` — 磁盘/子卷/generation
2. `architecture/boot.md` — 固件/UKI/TPM/initrd
3. `architecture/persistence.md` — canonical backing 不变量
4. `architecture/accounts-sessions.md` — 账户/登录/会话
5. `architecture/home.md` — Guix Home 与用户数据
6. `architecture/secrets.md` — 秘密管理与威胁模型
