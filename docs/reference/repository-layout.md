# Repository Layout

仓库顶层各目录的职责。不逐文件列举（以实际文件为准）。

```text
channels.scm          频道集合（上游来源声明）
channels.lock.scm     频道锁（实际使用的 commit）
manifests/            开发 / 安装 / secrets / Secure Boot 工具链 manifest
modules/guixcfg/      全部配置模块（-L modules 加入 load path）
  apps/                Application layer：model.scm + registry.scm +
                       <app>/definition.scm（纵向配置单元；公开配置与
                       app-private secrets colocate）
  boot/                initrd、UKI、TPM 解锁、boot-state、Recovery
  home/                Guix Home 入口（薄 assembly，聚合 apps registry）
  hosts/               host 组装点（vm / laptop）+ host-owned inventory
                       （vm-secrets.scm）
  security/            age、secrets、TPM2、证书
  services/            用户态 one-shot 服务（ephemeral-root）
  storage/             磁盘/子卷/generation 纯模型 + 安装器
  system/              OS 组装、readiness、accounts、ssh、
                       user-persistence、application-persistence
  users/               用户结构事实
  utils/               跨领域原语（atomic-file / process / spawn /
                       repository-source）
tools/                 命令行工具（disk-install、secrets、secure-boot、reconfigure、
                       tpm2-enroll、历史 E2E harness）
templates/            新组件模板（application/definition.scm）
secrets/              age 密文（明文永不入库；system/shared/install/
                      bootstrap/hosts 集中域；app-private 在
                      apps/<app>/secrets/）
tests/                测试（run-tests.scm 入口 + 各主题 test-*.scm）
docs/                 文档（本目录）
vms/                  测试 VM 产物（qcow2、OVMF VARS、swtpm state；gitignore）
```
