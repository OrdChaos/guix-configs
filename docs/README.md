# Documentation

Guix System 配置工程的文档入口。

## 第一次看这个项目从哪里开始

推荐阅读顺序：

1. [architecture/overview.md](architecture/overview.md) — 30 分钟理解整个系统
2. [architecture/storage.md](architecture/storage.md) — 磁盘、子卷、generation
3. [architecture/boot.md](architecture/boot.md) — 固件、UKI、TPM
4. [architecture/persistence.md](architecture/persistence.md) — canonical backing 不变量
5. [architecture/accounts-sessions.md](architecture/accounts-sessions.md) — 账户、登录、会话
6. [architecture/home.md](architecture/home.md) — Guix Home 与用户数据
7. [architecture/secrets.md](architecture/secrets.md) — 秘密管理与威胁模型
8. [architecture/flatpak.md](architecture/flatpak.md) — Flatpak 子系统
9. [architecture/gsettings.md](architecture/gsettings.md) — repository-derived GSettings → dconf 投影

然后按需：

- **安装系统** → [operations/installation.md](operations/installation.md)
- **日常更新** → [operations/reconfigure.md](operations/reconfigure.md)
- **系统坏了** → [operations/recovery.md](operations/recovery.md)
- **测试 VM** → [operations/vm-testing.md](operations/vm-testing.md)
- **开发规则** → [development/invariants.md](development/invariants.md)、
  [development/conventions.md](development/conventions.md)、
  [development/testing.md](development/testing.md)
- **还有什么没做** → [development/roadmap.md](development/roadmap.md)
- **仓库布局** → [reference/repository-layout.md](reference/repository-layout.md)

## 文档约定

- 一个事实只有一个 canonical explanation；操作文档链接架构文档，
  不重复原理。
- 历史测试结果/阶段报告不进文档（Git history 就是历史）。
- 未完成事项只进 roadmap。
