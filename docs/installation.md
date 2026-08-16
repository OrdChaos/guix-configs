# 安装流程与安全要求


---

# 30. 安装流程

## 30.1 LiveCD 仓库位置

通过 9p 共享挂载（VM）或 clone 到：

```text
/root/guix-configs
```

## 30.2 Bootstrap（含 stable identity S）

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

### 30.2.1 解锁 stable identity S（安装 secrets 的前提）

安装需要的 secret（LUKS recovery credential、用户密码 hash）由
stable identity S 解密。**master password 全程只输入一次**：

```bash
guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L modules -s tools/secrets.scm unlock
```

`manifests/secrets.scm` 提供工具链（age 加解密、util-linux 的
script 伪终端——age 的 passphrase 只从 /dev/tty 读、coreutils 的
stty——密码 noecho 读取）。

提示输入 master password 一次（不回显；stty 缺失时明确报错而不是
静默回显），得到 `/run/guixcfg-age/stable-identity`
（0600，tmpfs）。之后所有 install secret 的解密都复用它，不再提示。

如果跳过本步（纯交互安装），LUKS 密码走人工输入路径，用户密码在
首次启动后用 `tools/secrets.scm provision-password` 单独设置——见
30.3.3。

## 30.3 安装阶段

```text
解锁 stable identity S（master password 一次）
→ 检查目标设备
→ 显示磁盘信息
→ 验证目标未挂载
→ 验证不是 LiveCD 系统盘
→ 验证容量
→ 打印完整 plan
→ 要求输入完整设备路径确认
→ GPT
→ ESP
→ LUKS2（交互密码，或 --luks-secret 用 S 解密 luks-recovery.age）
→ Btrfs
→ 持久子卷
→ swapfile
→ @root-installing
→ 挂载 /mnt
→ herd start cow-store /mnt
→ （可选）生成 Secure Boot PK/KEK/db
→ guix system init（含 UKI/Limine 部署；有密钥则直接签名）
→ secrets install（S → /persist/system/keys/age/identity）
→ provision-password（hash → /persist/system/accounts/<user>/）
→ commit-root（收养 /var/guix → @root-template/@root-0 → 初始状态
   → 重跑部署刷新 ESP 菜单）
→ （可选）构建 Secure Boot 注册材料并写入固件
→ reboot
```

### 30.3.1 磁盘安装

```bash
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda
```

（`manifests/installer.scm`：gptfdisk/cryptsetup/btrfs-progs/dosfstools/
util-linux/coreutils/age——`age` 供 `--luks-secret` 的解密路径。）

这里有意使用 LiveCD 当前的普通 `guix repl`，而不是 `guix time-machine`：
此阶段 `/gnu/store` 还在 LiveCD 的内存盘上，只需要纯 storage policy 与磁盘
操作模块；Rosenthal/Nonguix 等 channel 依赖直到 `herd start cow-store /mnt`
之后的 `system init` 才加载。

**LUKS passphrase 两种来源**（docs/secrets.md 第 15.5 节）：

```bash
# 交互输入（默认，两次确认）
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda

# 或：从 stable S 解密 secrets/install/luks-recovery.age（需 30.2.1 已 unlock）
guix shell -m manifests/installer.scm -- \
  guix repl tools/disk-install.scm -- apply vm /dev/vda --luks-secret
```

两条路径共用 installer 的 stdin 语义；明文只在内存，不进
argv/environment/store/日志。

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

### 30.3.3 安装 stable identity 与用户密码（首次启动前）

`system init` 之后、`commit-root` 之前，把安装期解密的 stable S 落到
LUKS 内的 persist（日常 boot 全靠它，不再需要 master password）：

```bash
# /mnt/persist 已挂载；S 来自 30.2.1 的 /run 临时副本
install -d -m 700 /mnt/persist/system/keys/age
install -m 600 /run/guixcfg-age/stable-identity \
  /mnt/persist/system/keys/age/identity
```

（在已安装系统内可用 `tools/secrets.scm verify` 验证：installed S
推导的 recipient 必须与仓库 `secrets/recipients/stable.agepub` 一致，
否则 fail closed。）

然后物化用户密码 hash（persistent authoritative credential）：

```bash
# LiveCD 安装期：写目标系统的 /mnt/persist（accounts 目录前缀经
# 环境变量覆盖；工具链由 manifests/secrets.scm 提供）
GUIXCFG_ACCOUNTS_DIR=/mnt/persist/system/accounts \
  guix time-machine -C channels.lock.scm -- \
  shell -m manifests/secrets.scm -- \
  guile -L modules -s tools/secrets.scm provision-password user \
  secrets/install/user-password.hash.age
```

（已安装系统内日常 provision——密码更新——则不带前缀，直接写
`/persist/system/accounts/`。）

它把 hash 写到 `/mnt/persist/system/accounts/user/password.hash`
（root 0700/0600）。**只保存 hash，不保存明文密码**。

每次启动时，`guixcfg-password-project`（one-shot）把它投影进 ephemeral
`/etc/shadow`——密码改动的唯一官方路径是：可信环境生成新 hash → 更新
`user-password.hash.age` → 重新 provision。运行期 `passwd` 不持久
（ephemeral root），属 unsupported workflow。

### 30.3.4 安装期提交

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
Secure Boot enrollment（30.3.5）。

重复执行是安全 no-op（committed predicate：@root-0 + state 均存在）；
rename 后中断的提交会在下次运行时自动恢复完成。Previous 菜单项在
首次启动后的下次部署出现（state 最后写，commit 时 deploy 尚在
first-boot 之前）。

首次启动由 initrd 里的无状态根逻辑接管。菜单语义见 docs/boot.md
第 16.1 节；`rootmode=` 参数见 docs/storage.md 第 17.6 节。

### 30.3.5 首次启动验收（readiness 链）

首次正常启动（TPM 自动解锁或人工密码）后，系统按 Boot Readiness
Contract（docs/system-home-boundaries.md J8）启动：

```text
file-systems → persistent-state-ready
  → {account projection（password projector）∥ runtime secrets 发布}
  → user-processes → {elogind ∥ Guix Home activate}
  → {session-infra-ready ∥ home-ready}
  → interactive-session-ready → 打开 login gate
  → login:（tty）/ SSH
```

验收点：

- **login: 出现 = interactive-session-ready 已过**（tty prompt 被
  mingetty requirement 延迟到 barrier 后）；
- SSH 在 gate 未开时会被 PAM 拒绝（"The system is not ready for
  interactive logins yet."）——这是预期行为，不是故障；
- 登录后 `XDG_RUNTIME_DIR=/run/user/<uid>` 已由 elogind 提供；
- `~/.guix-home`、dotfile 链接已由 guix-home-user 重建；
- `/run/guixcfg-secrets/…` 里的 runtime secrets 已发布（当前 VM 为
  测试 sentinel）。

如果某个 prerequisite 失败：gate 保持关闭，普通新 session 被拒；
修复后用 `tools/reconfigure.sh`（或 herd restart 相应服务）恢复，
无需 reboot。

### 30.3.6 Secure Boot 固件注册（可选）

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

如果 LiveCD 中因 `efitools` 没有 substitute 而触发本地构建且构建失败，
**不需要因此阻塞系统安装**。正确做法：保持 Secure Boot 关闭，
先启动安装好的 Guix System，再在目标系统中运行同一 enrollment 流程，此时路径改为：

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

### 30.3.7 TPM2 PCR7 enrollment（可选，Secure Boot 启用后）

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

## 30.4 日常 reconfigure

正式入口（configctl system switch 的 VM 阶段最小实现）：

```bash
sudo tools/reconfigure.sh        # 在仓库根目录运行
```

事务语义（docs/system-home-boundaries.md J5/J8）：

```text
关闭 login gate（新 session 拒绝；已有 session 不动）
  → guix time-machine … system reconfigure
  → shepherd 升级自动 restart 变化的 one-shot 服务
    （runtime secrets 代际发布、password 投影、Home 热激活）
  → 验证 Home 链接与 readiness capability 无 failed
  → 打开 gate
```

失败语义：

```text
reconfigure 失败          → gate 重开（无状态变化），exit 1
system 成功 + Home 失败   → gate 保持关闭，exit 2；
                            修复后重跑本脚本恢复（无需 reboot）
```

## 30.5 仓库复制

安装完成前，把同一 Git commit 部署到：

```text
/mnt/persist/data-home/<user>/guix-configs
```

目标系统中暴露为：

```text
~/guix-configs
```

正式安装默认拒绝脏工作区。

## 30.6 安装记录

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

（当前只有文档约定；configctl 实现后由工具自动写入。）

## 30.7 回滚与恢复

- **Last Good / Recovery**：boot 菜单（Limine）选择；任一旧
  generation 启动都重新经过完整 readiness 链（不绕过 barrier）。
- **secrets 恢复**：master password → `tools/secrets.scm unlock` →
  原 ciphertext 无 rekey 即可解密（stable S 模型，
  docs/secrets.md 15.6）。
- **密码/账户恢复**：provision 新 hash（30.3.3）或直接编辑
  `/persist/system/accounts/<user>/password.hash`（root）。
