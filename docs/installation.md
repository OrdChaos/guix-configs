# 安装流程与安全要求


---

# 30. 安装流程

## 30.1 LiveCD 仓库位置

通过 9p 共享挂载（VM）或 clone 到：

```text
/root/guix-configs
```

## 30.2 Bootstrap

当前没有 configctl；安装命令是直接的 `guix repl` / `guix system` 调用。
LiveCD 环境（VM 内）：

```bash
mkdir -p /root/src && mount -t 9p -o trans=virtio guix-configs /root/src && cd /root/src
```

注意：LiveCD 的根是内存盘，`/gnu/store` 也在内存里。磁盘安装完成、目标挂载到 `/mnt` 之后、执行任何 time-machine 或 `system init` 之前，必须先执行：

```bash
herd start cow-store /mnt
```

把 store 转移到目标磁盘上，否则下载和构建会写满内存盘（低内存 VM 尤其如此）。安装器在磁盘安装结束时会检测 `/gnu/store` 是否仍在 tmpfs 上，是则醒目提醒执行这一步。

cow-store 环境下 `system init` 的另一个坑：init 会先 `delete-file-recursively` 删除目标的 `/var/guix` 重新开始注册，而挂载点删不掉（EBUSY）。因此 **`@persist-var-guix` 在 init 期间刻意不挂载**（`mount-at-install? #f`），让 `/var/guix` 以普通目录建在 `@root-installing` 里——init 看到的是完全原生的环境，profile 注册、store 数据库全部正常落盘。安装期提交（`commit-root`）在快照之前把这份内容收进 `@persist-var-guix` 子卷，模板里留下空目录作运行时挂载点。

## 30.3 安装阶段

```text
检查目标设备
→ 显示磁盘信息
→ 验证目标未挂载
→ 验证不是 LiveCD 系统盘
→ 验证容量
→ 打印完整 plan
→ 要求输入完整设备路径确认
→ GPT
→ ESP
→ LUKS2
→ Btrfs
→ 持久子卷
→ swapfile
→ @root-installing
→ 挂载 /mnt
→ herd start cow-store /mnt
→ （可选）生成 Secure Boot PK/KEK/db
→ guix system init（含 UKI/Limine 部署；有密钥则直接签名）
→ commit-root（收养 /var/guix → @root-template/@root-0 → 初始状态
   → 重跑部署刷新 ESP 菜单）
→ （可选）构建 Secure Boot 注册材料并写入固件
→ reboot
```

### 30.3.1 磁盘安装

```bash
guix shell gptfdisk cryptsetup btrfs-progs dosfstools util-linux -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda
```

这里有意使用 LiveCD 当前的普通 `guix repl`，而不是 `guix time-machine`：
此阶段 `/gnu/store` 还在 LiveCD 的内存盘上，只需要纯 storage policy 与磁盘
操作模块；Rosenthal/Nonguix 等 channel 依赖直到 `herd start cow-store /mnt`
之后的 `system init` 才加载。

### 30.3.2 系统安装

首先把 Guix store 转移到目标盘：

```bash
herd start cow-store /mnt
```

如果本次安装准备启用 Secure Boot，并希望第一次生成的 UKI 就已经签名，
应当在 `system init` **之前**生成密钥：

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-keygen.scm -- \
  guix repl tools/secure-boot-keygen.scm \
  /mnt/persist/system/keys/secure-boot
```

该步骤只生成：

```text
PK.key  PK.crt
KEK.key KEK.crt
db.key  db.crt
```

不生成固件 enrollment 材料，也不会依赖 `efitools`。

然后安装系统：

```bash
GUIX_CONFIG_FACTS=/mnt/persist/system/facts/host.scm \
  guix time-machine -C channels.lock.scm -- system init \
  -L modules modules/guixcfg/hosts/vm.scm /mnt
```

如果 `db.key` 与 `db.crt` 已存在，UKI 和 Limine 会在部署时自动签名；
不存在时则生成未签名的开发期启动环境。

### 30.3.3 安装期提交

```bash
guix repl tools/disk-install.scm -- commit-root /mnt
```

依次执行（rename 语义，见 storage/commit.scm 头部注释与
tests/test-commit-root.scm）：收养 `/var/guix` 进 `@persist-var-guix`
（幂等）→ 发布只读 `@root-template`（ro=true 校验）→
**rename** `@root-installing` → `@root-0`（不再删除挂载源——删除
会让 TARGET 视图失效，实测 bug）→ 验证 TARGET 不变式
（etc/gnu/persist/boot）→ **重跑 UKI 部署**（rename 后 TARGET
视图保持，deploy 实际执行）→ **最后**写初始 root generation 状态
（`first-boot`，原子写——state 是 commit record，deploy 成功后才
宣布提交）。之后不要立即卸载重启：后面可能还要在 LiveCD 里执行
Secure Boot enrollment（30.3.4）。

重复执行是安全 no-op（committed predicate：@root-0 + state 均存在）；
rename 后中断的提交会在下次运行时自动恢复完成。Previous 菜单项在
首次启动后的下次部署出现（state 最后写，commit 时 deploy 尚在
first-boot 之前）。

首次启动由 initrd 里的无状态根逻辑接管。菜单语义见 docs/boot.md
第 16.1 节；`rootmode=` 参数见 docs/storage.md 第 17.6 节。

### 30.3.4 Secure Boot 固件注册（可选）

注册材料与密钥生成分离。

只有在 PK/KEK/db 已生成、且 UKI/Limine 已使用 `db` 密钥完成签名后，
才构建 enrollment keystore：

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-enroll.scm -- \
  guix repl tools/secure-boot-enroll.scm \
  /mnt/persist/system/keys/secure-boot
```

该步骤负责：

```text
自有 PK/KEK/db
+ Microsoft compatibility certificates
+ KEKDefault/dbDefault
→ keystore/{PK,KEK,db}/*.auth
```

然后在固件 Setup Mode 下注册：

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secure-boot-enroll.scm -- \
  sh -c '
    sbkeysync \
      --keystore /mnt/persist/system/keys/secure-boot/keystore \
      --verbose &&
    sbkeysync \
      --keystore /mnt/persist/system/keys/secure-boot/keystore \
      --verbose --pk
  '
```

PK 最后写入。

如果 LiveCD 中因 `efitools` 没有 substitute 而触发本地构建，并在 Guix
daemon 的 `mountIntoChroot` 阶段失败（`bind mount ... guix-build-efitools
... No such file or directory`），**不需要因此阻塞系统安装**。该错误发生在
真正编译 `efitools` 之前：前面的依赖拿到了 substitute，而 `efitools` 恰好
没有，于是触发了本地 sandbox build——问题属于 installer LiveCD 的
cow-store / `/gnu/store` / guix-daemon build sandbox 挂载环境，不是
`efitools` 源码本身无法编译。`guix time-machine` 只更换 Guix client 与
package definition，并不会替换 LiveCD 上正在运行的 guix-daemon；也不要
手工创建 `/tmp/guix-build-*` 或 `.drv.chroot` 来绕过。正确做法：保持
Secure Boot 关闭，先启动安装好的 Guix System，再在目标系统中运行同一
enrollment 流程，此时路径改为：

```text
/persist/system/keys/secure-boot
```

如果密钥是在第一次启动以后才生成的，则在 enrollment 前必须先
`guix system reconfigure` 一次，以重新生成已经签名的 UKI/Limine。

最后：

```bash
swapoff -a
umount -R /mnt
reboot
```

### 30.3.5 TPM2 PCR7 enrollment（可选，Secure Boot 启用后）

Secure Boot 已启用并完成一次带最终 NVRAM policy 的正常启动后
（SecureBoot==1 且 SetupMode==0），在目标系统上以 root 执行：

```bash
guix shell tpm2-tools cryptsetup --   guix repl tools/tpm2-enroll.scm -- preflight
guix repl tools/tpm2-enroll.scm -- enroll      # 首次 enrollment
guix repl tools/tpm2-enroll.scm -- status      # 查看状态
guix repl tools/tpm2-enroll.scm -- replace     # Secure Boot policy 变化后
```

enrollment 把独立随机 credential 密封到当前 PCR7 并加入独立 LUKS
keyslot；recovery 密码 keyslot 始终保留。此后普通 UKI/kernel/initrd
更新无需重新 enrollment；PK/KEK/db 变化导致 PCR7 变化后，启动会回退
密码，再用 `replace` 重新 enrollment。流程见 docs/boot.md 第 16.4 节。

## 30.4 仓库复制

安装完成前，把同一 Git commit 部署到：

```text
/mnt/persist/data-home/<user>/guix-configs
```

目标系统中暴露为：

```text
~/guix-configs
```

正式安装默认拒绝脏工作区。

## 30.5 安装记录

保存：

```text
配置 Git revision
channel revisions
目标 host
安装时间
磁盘设备
生成的 UUID
安装器版本
```

位置：

```text
/persist/system/install/
```
