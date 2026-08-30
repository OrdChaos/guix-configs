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
<模块>/secrets/*.age（密文与引用者同置，见下方 taxonomy）
        ↓ build（ciphertext 允许进 store）
/gnu/store/<hash>-secret.age
        +
/persist/system/keys/age/identity   ← stable identity S
        ↓ decrypt（boot 时，root）
/run/guixcfg-secrets/...
```

使用 age 整文件加密，不使用 SOPS 字段级加密。

**两个不同的概念：ownership 与 deployment target**：

```text
ownership         = 为什么这个 ciphertext 存在、哪个配置单元负责它
deployment target = 解密后给谁 / 放在哪里（scope：system / user）
```

`system/user` **不是** repository ownership 的完整分类。例如一个
最终以用户权限发布的 SSH secret：`owner = openssh application`、
`target scope = user`——位于 `apps/openssh/secrets/...`，而不是因为
target 是 user 就放进 `secrets/user/`。

**Repository ownership taxonomy（唯一规则：密文与引用者同置）**：

```text
app 密文             → apps/<app>/secrets/*.age（该 app 的
                       definition.scm 声明；source-relative local-file）
系统组件密文         → modules/guixcfg/<域>/<组件>/secrets/*.age
                       （如 mihomo：system/mihomo/secrets/
                       mihomo-subscription.url.age，decl 由
                       (guixcfg system mihomo service) 导出；
                       单份密文、所有设备共用——无 host 层）
机制自身密钥         → modules/guixcfg/security/secrets/age/
                       {stable.agepub, stable-identity.age}
                       （age 机制唯一读写者；repo-root 相对路径）
install / recovery   → modules/guixcfg/security/secrets/
                       luks-recovery.age（credential-source 唯一
                       生产消费者）
user 域 provisioning → modules/guixcfg/users/secrets/
                       user-password.hash.age
测试 sentinel         → tests/fixtures/secrets/*.age（测试域；VM
                       测试机装配经 repository-file 组合）
```

> 已取消的层：`secrets/hosts/<host>`（host-owned 层）、顶层
> `secrets/` 目录。`system/user` 是 deployment target/scope，不是
> repository ownership 类别；`hosts/vm-secrets.scm` 这类 host
> inventory 模块不再存在——密文各归引用者。

generic publisher（`(guixcfg security secrets)`）不知道任何具体
inventory；`secret-decl-source` 是 **file-like**（ciphertext 由
调用者解析——模块内密文用 source-relative `local-file`；tests/
fixtures 密文由 VM 测试机装配经唯一 repo-root resolver
`(guixcfg utils repository-source)` 引用）。inventory 声明在各
引用者模块（app definition / 系统组件模块 / VM 装配点），不混入
generic security mechanism。

bootstrap/recipients 属于 **tooling plane**（repo-relative CLI
input → tools/secrets.scm 的 age lifecycle）——**不转换成
secret-decl**，不进 store/publisher（它们不是 system-generation
runtime secret）；install（luks-recovery / user-password.hash）由
provisioning 流程消费（credential-source / provision-password），
同样不成为 runtime secret-decl。

### 可变应用状态

真实数据在 `/persist/data-app/<application>`，经 bind mount 或
symlink 暴露到应用默认路径（如 `/persist/data-app/flatpak/
installation` → `~/.local/share/flatpak`，以及每 Catalog app 的
`/persist/data-app/flatpak/apps/<id>` → `~/.var/app/<id>`——详见
`architecture/flatpak.md`）。不执行每次开机复制。映射由系统层
`file-systems` 声明（bind mount），在用户会话和依赖服务启动前完成；
不使用 Home 层实现系统级挂载。

### Secret Service secret ≠ declarative secret

`org.freedesktop.secrets`（GNOME Keyring，`apps/gnome-keyring`——
`desktop-authentication.md`）里的 secret 是 **runtime
application/user authority**：应用经 libsecret/D-Bus 写入，vault
持久在 `~/.local/share/keyrings`（bind 到 `/persist/data-app/
gnome-keyring/keyrings`），**不属于本文件的 declarative secret
taxonomy**。两者不互相转换：未来 Chrome Safe Storage 材料属于前者；
预声明的 deployment API token 属于后者。

### Keyring master credential 是 declarative secret（新模型）

GNOME Keyring 的 **master credential 本身**是 repository-owned
declarative secret：`apps/gnome-keyring/secrets/master.age`（单一
app owner——ciphertext colocate 到 app 目录，AGENT.md §Application
layer）。runtime 经 ordinary publisher 解密到
`/run/guixcfg-secrets-ordinary/users/<user>/gnome-keyring-master`
（owner=user，mode 0400；plaintext 仅存在于 /run，用户明确接受）。
domain = **ordinary**——解密失败绝不阻塞 greetd login（login-critical
vs ordinary 两个独立 publisher；本 secret 走 ordinary 侧）。

master credential 是 **stable credential**：normal reconfigure 不
轮换；rollback 不回滚 mutable vault；rotation 是显式维护操作
（先 rekey vault 再切换 runtime secret）。

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

`modules/guixcfg/security/secrets/age/stable-identity.age`（passphrase
加密私钥）位于 public repo，给攻击者离线尝试 master passphrase 的目标。长期选择：
public repo 只含 recipient + ciphertext、private identity 另存密码
管理器；或维持现状但 master passphrase 必须高熵、独立于登录密码。
不擅自迁移（见 development/roadmap.md）。

## 用户密码：credential 三层模型

```text
modules/guixcfg/users/secrets/user-password.hash.age（加密
provisioning source）
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

`modules/guixcfg/security/secrets/luks-recovery.age`（age-encrypted
LUKS recovery
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

三个正交维度：

```text
owner            = 为什么存在、哪个配置单元负责它（app / host / shared / system）
deployment target = 解密后给谁、放哪里（scope：system / user）
readiness domain  = 失败影响范围（login-critical / ordinary）
```

`<secret-decl>` 的 `domain` 字段（显式必填）声明 readiness domain：
- **login-critical**：失败 → `interactive-secrets-ready` 不成立 → login
  gate 保持关闭；
- **ordinary**：失败 → `ordinary-secrets-ready` 不成立、shepherd 明确
  报告失败——**绝不阻止 interactive login**。

两个 domain 拥有**完全独立**的 publication transaction（staging /
generation / current root / Shepherd service / capability）：

```text
login-critical   /run/guixcfg-secrets.d/<N>  → /run/guixcfg-secrets
                 （provision interactive-secrets-ready；login gate 依赖）
ordinary         /run/guixcfg-secrets-ordinary.d/<N>
                 → /run/guixcfg-secrets-ordinary
                 （provision ordinary-secrets-ready；不 gate login）
```

- domain 内 atomic/fail-closed：任一 secret 解密失败 → 本 domain 不
  发布新 generation（旧代保留）；
- domain 间 failure-isolated：ordinary 失败不影响 login-critical
  发布；login-critical 失败不能被 ordinary 成功掩盖；
- 不 catch-and-ignore 解密错误；
- composition root 在 host/system assembly（`applications-secrets`
  聚合 + host-owned inventory → 按 domain 分区 → generic publisher
  实例）——security/secrets.scm 只做 mechanism。
- scope 语义：install（仅安装/恢复消费，不 runtime 部署）、system
  （→ <domain-root>/system/）、user（→ <domain-root>/users/<user>/，
  owner=user 0600）。
- boot 时由对应 domain 的 deploy 服务用 installed stable S 一次性
  解密到 domain root（tmpfs），generation publication（原子 symlink
  切换），consumer 永远看到完整旧代或完整新代。
- 缺 identity 或解密失败：服务明确 failed（不询问 master password、
  不打断 boot——消费方因缺 secret 而失败）。
- 明文 secret 只存在于 /run（tmpfs）与内存。
