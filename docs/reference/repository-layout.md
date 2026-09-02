# Repository Layout

仓库顶层各目录的职责。不逐文件列举（以实际文件为准）。

```text
channels.scm          频道集合（上游来源声明）
channels.lock.scm     频道锁（实际使用的 commit）
assets/               仓库派生的用户资源（avatar/wallpaper——经
                       (guixcfg home assets) 声明式安装到
                       ~/.local/share/avatars|backgrounds/）
manifests/            开发 / 安装 / secrets / Secure Boot 工具链 manifest
modules/guixcfg/      全部配置模块（-L modules 加入 load path）
  apps/                Application layer：model.scm + registry.scm +
                       selection.scm（configuration variant
                       selection：application 声明变体，host 只做
                       logical selection）+ <app>/definition.scm
                       （纵向配置单元；公开配置、variants/ 与
                       app-private secrets colocate）
  boot/                initrd、UKI、TPM 解锁、boot-state、Recovery、
                       layout（ESP/部署路径固定事实的唯一 authority）
  flatpak/             Flatpak 平台（docs/architecture/flatpak.md）：
                       model.scm（remote/application/override 记录 +
                       校验 + reconcile plan + override renderer）、
                       registry.scm（Catalog %flatpak-applications +
                       Selection %flatpak-selection，fail-fast）、
                       service.scm（离线 Home 集成：override 完整
                       文件 + XDG_DATA_DIRS + persistence rules；
                       零 flatpak CLI）、reconcile.scm（sync/status/
                       update/remove/gc 操作层，唯一联网面，只被
                       Blue 的 flatpak 命令消费）
  gsettings/           Repository-derived GSettings（docs/architecture/
                       gsettings.md）：model.scm（<gsettings-setting> +
                       校验 + (schema,key) 单一 owner 硬规则 +
                       appearance 保留域）、serialize.scm（schema→
                       dconf path + 确定性 keyfile）、runtime.scm
                       （唯一 runtime contract，core-guile-only——
                       reconcile include-from-path + wrapper
                       local-file/load 双消费）、reconcile.scm
                       （manual 路径 thin 包装，PATH 解析工具）、
                       home-service.scm（参数化 one-shot service；
                       desired 声明 build-time 嵌入）
  home/                Guix Home 入口（薄 assembly，聚合 apps
                       registry；guix-home 接受 host 的 logical
                       application-configuration-selections）+ 会话
                       环境变量（environment.scm）
  hosts/               host 组装点（vm / laptop）+ 共享组装算法
                       common.scm（services / user-services / 基础 OS
                       / account fold 的四个窄构造函数，deploy 枚举
                       排除）；host-owned inventory = %vm-test-secrets
                       （hosts/vm.scm 内的测试 sentinel，无独立
                       secrets 文件）；host 对应用只做 logical
                       variant selection（不持有应用配置文件）
  security/            age、secrets、TPM2、证书；enroll.scm
                       （blue enroll 的 machine-bound enrollment
                       编排：TPM/SB 状态探测、计划、幂等判定、
                       固件写入确认——TPM/SB mutation 机制仍归
                       tools/tpm2-enroll.scm 与 secure-boot 工具）
  services/            用户态 one-shot 服务（ephemeral-root）
  storage/             磁盘/子卷/generation 纯模型 + 安装器
  system/              OS 组装、readiness、accounts、ssh、
                       user-persistence、application-persistence、
                       session-gate（login gate 唯一 authority：
                       path/close/open/message + activation gexp
                       builder）、install.scm（blue install 的安装
                       编排：preflight/阶段检测/resume/事务/验证——
                       disk mutation 机制仍归 storage/install）、
                       mihomo/（系统透明代理
                       service/config/template，
                       docs/architecture/mihomo.md）
  users/               用户结构事实
  utils/               跨领域原语（atomic-file / process / spawn /
                       repository-source / home-path / mountinfo /
                       seed-once / paths / module-closure）
  fonts/               共享字体事实（single source；中立域，system
                       层不 import home 层）：model.scm（%fonts 包
                       集合）+ fontconfig-policy.scm（generic-family/
                       fallback 策略 SXML 数据）——Home profile、
                       System profile 的 Flatpak sandbox 字体投影、
                       ONLYOFFICE 兼容层（apps/onlyoffice）共同消费
tools/                 独立领域 CLI（刻意留在 Blue 之外：disk-install、
                       secrets、secure-boot、tpm2-enroll、历史 E2E
                       harness；reconfigure 事务与 Flatpak 已迁入
                       Blue/domain module，不再属于这里）
templates/            新组件模板（application/definition.scm 原生应用、
                       flatpak-application/definition.scm Flatpak 应用）
secrets 密文          密文与引用者同置：apps/<app>/secrets/、
                      modules/guixcfg/<域>/<组件>/secrets/、
                      tests/fixtures/secrets/（测试 sentinel）；
                      无 host-owned 层、无顶层 secrets/ 目录；
                      machine-generated state 不在此，在
                      /persist/system/state；readiness domain
                      （login-critical/ordinary）是 secret-decl 属性，
                      不改变 repository 布局
tests/                测试（run-tests.scm 入口 + 各主题 test-*.scm）
docs/                 文档（本目录；application layer 见
                      architecture/applications.md +
                      development/applications.md）
vms/                  测试 VM 产物（qcow2、OVMF VARS、swtpm state；gitignore）
```
