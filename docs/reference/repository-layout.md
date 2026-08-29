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
  home/                Guix Home 入口（薄 assembly，聚合 apps
                       registry；guix-home 接受 host 的 logical
                       application-configuration-selections）+ 会话
                       环境变量（environment.scm）
  hosts/               host 组装点（vm / laptop）+ host-owned inventory
                       （vm-secrets.scm）；host 对应用只做 logical
                       variant selection（不持有应用配置文件）
  security/            age、secrets、TPM2、证书
  services/            用户态 one-shot 服务（ephemeral-root）
  storage/             磁盘/子卷/generation 纯模型 + 安装器
  system/              OS 组装、readiness、accounts、ssh、
                       user-persistence、application-persistence、
                       mihomo/（系统透明代理 service/config/template，
                       docs/architecture/mihomo.md）
  users/               用户结构事实
  utils/               跨领域原语（atomic-file / process / spawn /
                       repository-source / home-path / mountinfo /
                       seed-once / paths / module-closure）
tools/                 命令行工具（disk-install、secrets、secure-boot、reconfigure、
                       tpm2-enroll、历史 E2E harness）
templates/            新组件模板（application/definition.scm）
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
