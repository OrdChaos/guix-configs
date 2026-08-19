# Secrets Architecture

配置/秘密/可变状态分类、stable identity S 模型、credential 三层、
runtime secrets、威胁模型。操作命令在 `operations/installation.md`。

## 配置分类

所有文件按所有权分为五类。

### 公开、只读、声明式配置

```text
modules/guixcfg/apps/<app>/...（公开配置与 definition colocate）
        ↓ system/home build
/gnu/store/<hash>-...
        ↓ symlink
/etc/... 或 ~/.config/...
```

不需要复制进 `/persist`。

### age 加密整文件

```text
secrets/.../*.age 或 apps/<app>/secrets/*.age
        ↓ build（ciphertext 允许进 store）
/gnu/store/<hash>-secret.age
        +
/persist/system/keys/age/identity   ← stable identity S
        ↓ decrypt（boot 时，root）
/run/guixcfg-secrets/...
```

使用 age 整文件加密，不使用 SOPS 字段级加密。

**Secret ownership 分布（mechanism centralized）**：

```text
单一 app owner       → apps/<app>/secrets/*.age（由该 app 的
                       definition.scm 声明）
多消费者 / 共享      → secrets/shared/
system / machine     → secrets/system/、secrets/hosts/
install / bootstrap  → secrets/install/、secrets/bootstrap/
recipients           → secrets/recipients/
```

generic publisher（`(guixcfg security secrets)`）不知道任何具体
inventory；`secret-decl-source` 是 **file-like**（ciphertext 由
caller 解析——app-local 用 source-relative `local-file`，top-level
集中 secrets 用唯一 resolver `(guixcfg utils repository-source)`）。
host-owned inventory 放在 host 模块附近（如
`(guixcfg hosts vm-secrets)` 的 `%vm-secrets`），不混入 generic
security mechanism。

### 可变应用状态

真实数据在 `/persist/data-app/<application>`，经 bind mount 或
symlink 暴露到应用默认路径（如 `/persist/data-app/flatpak` →
`~/.local/share/flatpak`）。不执行每次开机复制。映射由系统层
`file-systems` 声明（bind mount），在用户会话和依赖服务启动前完成；
不使用 Home 层实现系统级挂载。

### 仓库提供初始值、应用随后接管

```text
store 中的默认文件
      ↓ 仅首次复制
/persist/data-app/<app>/config
```

以后由应用维护，不强制覆盖。

### 运行时生成配置

```text
store 中公开模板 + /run/guixcfg-secrets 中的秘密
        ↓
/run/<app>/config.yaml
```

生成文件不持久化。

## 威胁模型

**保护目标**：攻击者只拿到公开配置仓库时，不能因此得到本机的登录
密码、stable private identity、或 runtime secrets 明文。

**PUBLIC REPOSITORY 不得包含**：plaintext login password、plaintext
stable private identity、直接暴露的 login verifier/hash、plaintext
runtime secrets。

**明确不防御**：攻击者已取得本机 root 或 LUKS 解锁后的 plaintext
访问能力（root 能读 password.hash、/etc/shadow、runtime secrets 均
被接受）。

**允许进 public repo**：recipient（公钥）、`.age` ciphertext、
passphrase 加密的 stable private identity（见下）。

## Stable identity S

- 一个个人 trust domain 只有一个长期稳定的 age identity S。
- 不使用 per-machine recipient；新机器安装不修改 repository。
- 生命周期：init（一次，age-keygen → recipient + passphrase 加密
  identity）→ unlock（master password 一次 → /run 临时 S）→
  install（S 落到 /persist/system/keys/age/identity，root 0600）→
  日常 boot 不需要 master password。
- installed S 明文存放于 LUKS-backed persist（root 0600）。
- plaintext secret 绝不进入 Guix store。
- 正常 boot 不 decrypt age、不读取 stable S 获取登录密码。

### 长期安全边界（roadmap）

`secrets/bootstrap/stable-identity.age`（passphrase 加密私钥）位于
public repo，给攻击者离线尝试 master passphrase 的目标。长期选择：
public repo 只含 recipient + ciphertext、private identity 另存密码
管理器；或维持现状但 master passphrase 必须高熵、独立于登录密码。
不擅自迁移（见 development/roadmap.md）。

## 用户密码：credential 三层模型

```text
secrets/install/user-password.hash.age（加密 provisioning source）
    ↓ 安装期 unlock S 解密
/persist/system/accounts/<user>/password.hash（persistent verifier，
    root 0600；normal boot 唯一读取的 credential input）
    ↓ 每 boot 由 account databases projection 内联
/etc/shadow 中 user 的 password 字段（ephemeral composite DB）
```

account databases projection 是 `/etc/{passwd,group,shadow}` 的唯一
writer（见 `architecture/accounts-sessions.md`）。normal boot 不
decrypt age、不访问 repo ciphertext。hash 不进 store/argv/log。

## LUKS recovery passphrase 的 install secret 消费（--luks-secret）

`secrets/install/luks-recovery.age`（age-encrypted LUKS recovery
passphrase）由两个 CLI 入口消费，来源解析统一走
`(guixcfg security credential-source)`（唯一实现；second
implementation 一律改为调用它）：

```text
disk-install apply --luks-secret      → luksFormat/luks-open 的 passphrase
tpm2-enroll enroll|replace --luks-secret → recovery passphrase 验证与 keyslot 操作
```

来源三选一且互斥（interactive / --luks-secret / --noninteractive）；
`--luks-secret` 在 runtime identity 缺失或解密失败时立即中止，绝不
静默回退交互输入；plaintext 只存在于进程内存与 /run 0600 中转文件，
不进 argv/env/log/store。`status`/`preflight` 不消费密码。

## Runtime secrets

- scope 语义：install（仅安装/恢复消费，不 runtime 部署）、system
  （→ /run/guixcfg-secrets/system/）、user（→
  /run/guixcfg-secrets/users/<user>/，owner=user 0600）。
- boot 时由 secrets-deploy 服务用 installed stable S 一次性解密到
  /run/guixcfg-secrets（tmpfs），generation publication（原子
  symlink 切换），consumer 永远看到完整旧代或完整新代。
- 缺 identity 或解密失败：服务明确 failed（不询问 master password、
  不打断 boot——消费方因缺 secret 而失败）。
- 明文 secret 只存在于 /run（tmpfs）与内存。
