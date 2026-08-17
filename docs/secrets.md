# 配置、秘密与可变状态


---

# 14. 静态配置、秘密和可变状态

所有文件按所有权分为五类。

## 14.1 公开、只读、声明式配置

流程：

```text
~/guix-configs/files/...
        ↓ system/home build
/gnu/store/<hash>-...
        ↓ symlink
/etc/... 或 ~/.config/...
```

例如：

```text
niri
Git
shell
终端
编辑器静态配置
Mihomo 公开模板
```

这些配置不需要复制进 `/persist`。

## 14.2 age 加密整文件

流程：

```text
~/guix-configs/secrets/.../*.age
        ↓ build（ciphertext 允许进 store）
/gnu/store/<hash>-secret.age
        +
/persist/system/keys/age/identity   ← stable identity S（见第 15 章）
        ↓ decrypt（boot 时，root）
/run/guixcfg-secrets/...
```

使用 age 整文件加密，不使用 SOPS 的字段级加密。

## 14.3 可变应用状态

真实数据位于：

```text
/persist/data-app/<application>
```

通过 bind mount 或符号链接暴露到应用默认路径。

例如：

```text
/persist/data-app/flatpak
    → ~/.local/share/flatpak
```

不执行每次开机复制。

挂载时机要求：这类映射由系统层 `file-systems` 声明（bind mount），在用户会话和任何依赖该路径的服务启动之前完成挂载；不使用 Home 层实现系统级挂载，避免“应用已启动但持久目录尚未挂载”的顺序问题。

## 14.4 仓库提供初始值、应用随后接管

适用于应用必须修改配置的情况：

```text
store 中的默认文件
      ↓ 仅首次复制
/persist/data-app/<app>/config
```

以后由应用维护，不再由仓库强制覆盖。

## 14.5 运行时生成配置

例如 Mihomo：

```text
store 中公开模板
+ /run/guixcfg-secrets 中的秘密
        ↓
/run/mihomo/config.yaml
```

生成文件不持久化。

---

# 15. Secret 管理（stable identity S 模型）

## 15.0 不变量

```text
1. 一个个人 trust domain 只有一个长期稳定的 age identity S。
2. 不使用 per-machine recipient。
3. 新机器安装不修改 repository。
4. public recipient + ciphertext + encrypted bootstrap identity 可进 Git。
5. master password 只解锁 S。
6. installed S 以明文存放于 LUKS-backed persist（root 0600）。
7. 正常 boot 不需要 master password。
8. TPM 只保护 LUKS；不再加 TPM secret 层。
9. plaintext secret 绝不进入 Guix store。
10. consumer 收到的是路径，不是 Scheme secret 值。
11. system secrets 在 /run（tmpfs）。
12. user secrets 在 /run/guixcfg-secrets/users/<user>/（owner=user 0600）。
13. LUKS recovery password 不以明文持久化在自己的卷里。
14. 结构性 user profile 与 secrets 是两个概念。
```

## 15.0.1 威胁模型（正式）

**保护目标**：攻击者只拿到公开配置仓库时，不能因此得到本机的登录
密码、stable private identity、或 runtime secrets 明文。

**PUBLIC REPOSITORY 不得包含**：

```text
- plaintext login password；
- plaintext stable private identity；
- 直接暴露的 login verifier/hash（默认原则：hash 即使不是明文，
  也只允许离线猜测者获得猜测目标，故也不进 public repo）；
- plaintext runtime secrets。
```

**明确不防御**：攻击者已取得本机 root 或 LUKS 解锁后的 plaintext
访问能力（此时 root 能读 password.hash、/etc/shadow、runtime
secrets 均被接受）。此边界由用户明确设定，不在本模型的防御范围内。

**允许进入 public repo**：recipient（公钥）、`.age` ciphertext、
passphrase 加密的 stable private identity（见 15.0.1.1 风险记录）。

### 15.0.1.1 stable identity 的长期安全边界（TODO，不擅自迁移）

当前模型：`secrets/bootstrap/stable-identity.age`（passphrase 加密的
私钥 S）位于 public repo。风险：public repo + encrypted private
identity 给攻击者一个**离线尝试 master passphrase 的目标**。

推荐长期选择之一（本轮不改变 provisioning architecture，写入 TODO）：

- A：public repo 只含 recipient + ciphertext；private identity 另存
  密码管理器/离线备份；
- B：repo 继续包含 passphrase-encrypted private identity，但 master
  passphrase 必须独立于登录密码、高熵、足以抵抗离线猜测。

当前阶段接受 B（master password 已独立于登录密码），长期按 A 演进。

### 15.0.1.2 未来 password rotation（TODO，不实现半套 CLI）

`configctl passwd`（或等价）的未来语义：

```text
generate new strong crypt hash
  → update encrypted provisioning source（user-password.hash.age）
  → atomically update installed persistent hash
  → trigger/revalidate account projection
  → preserve fail-closed semantics
```

不能长期依赖运行期 `passwd user`（只改 ephemeral /etc/shadow，reboot
后丢失）。

## 15.1 仓库布局

```text
secrets/
├── recipients/
│   └── stable.agepub          # recipient S（公钥，可进 Git）
├── bootstrap/
│   └── stable-identity.age    # passphrase 加密的私钥 S（可进 Git）
├── install/                   # install/recovery 输入
│   ├── user-password.hash.age # shadow 兼容 hash（非明文密码）
│   └── luks-recovery.age      # LUKS recovery credential
├── system/                    # runtime system secrets
└── user/                      # runtime user secrets
```

`.gitignore` 拦截明文私钥误提交（`secrets/**/*.key`、`secrets/**/identity*`）；
`.age` ciphertext 与 `.agepub` 公钥允许提交。

## 15.2 stable identity S 的生命周期

```text
init（仅一次）：
  age-keygen → S（内存）→ recipients/stable.agepub
             → age --passphrase（master password）→ bootstrap/stable-identity.age

unlock（fresh install / recovery）：
  master password（一次）→ 解密 stable-identity.age
  → /run/guixcfg-age/stable-identity（0600，tmpfs）
  → 安装全程复用（LUKS secret、password hash、其它 install secrets）

install（LUKS 建立、/persist 可用后）：
  /run 的 S → /persist/system/keys/age/identity（root:root 0700/0600）
  → recipient 校验（与仓库声明一致，否则 fail closed）

verify：
  installed S 推导 recipient == 仓库 stable.agepub，否则 fail closed。
```

工具：`tools/secrets.scm`（init/unlock/install/verify/lock/decrypt）。
master password 经 script 伪终端 stdin 交给 age（age 只从 /dev/tty 读
密语）；不进 argv/environment/log；明文 S 只在 /run 0600 临时文件。

## 15.3 密码学边界（已拍板）

```text
TPM  → LUKS（自动解锁，失败回退人工密码）
LUKS → 保护 installed stable S
age  → 保护 repository/deployment secrets
```

不给 age identity 或单个 secret 加 TPM sealing；不引入 age-plugin-tpm。
已解锁机器上的 root 可以取得 S 并解密全部 declarative secrets——这是
确定的信任模型，不是 bug。

## 15.4 Runtime secrets（boot 时一次性部署）

`guixcfg-secrets-deploy`（one-shot shepherd 服务，file-systems 后、
user-processes 前）用 installed S 解密到 tmpfs：

```text
/run/guixcfg-secrets/
├── system/<name>        # scope system：声明 owner/mode（如 root 0400）
└── users/<user>/<name>  # scope user：owner=<user>，0600
```

部署原子：同目录 `.new`（0600）→ chmod/chown → rename；age 失败不写
输出文件，不留 partial plaintext。缺 identity 时服务明确 failed
（不询问 master password、不打断 boot）。

scope 只表示权限/消费域，不是独立解密生命周期；第一版不把 user
secret 放进 `$XDG_RUNTIME_DIR`（session-bound lifecycle 记为 Future
Work）。`User Shepherd` 只消费已部署的路径，不做 privileged 解密。

## 15.5 Install secrets（user password hash + LUKS credential）

两者同属 install/recovery 输入：fresh install 时 unlock S 一次，
解密后消费；日常 boot/reconfigure/login 不再读取，更不需要 master
password。

### 用户密码 hash

仓库只保存 `user-password.hash.age`（shadow 兼容 hash，不是明文）。
`user-account` 的 password 字段恒为 `#f`（guixcfg/users/user.scm）——
hash 不进 evaluator/store。

**Credential 三层模型**（encrypted provisioning source → persistent
verifier → runtime account DB projection）：

```text
secrets/install/user-password.hash.age（加密 provisioning source）
    ↓ 安装期 unlock S 解密
/persist/system/accounts/<user>/password.hash（persistent verifier，
    root 0600；normal boot 唯一读取的 credential input）
    ↓ 每 boot 由 account databases projection 内联
/etc/shadow 中 user 的 password 字段（ephemeral composite DB）
```

account databases projection（guixcfg/system/accounts.scm）是
`/etc/{passwd,group,shadow}` 的**唯一 writer**——interactive 用户的
credential 在写库前从 persistent verifier 读入并校验（存在、形态合法、
非 locked），写库后验证最终 shadow（user 存在、hash == verifier、
非 empty/!/locked）才成功。不存在独立的第二 shadow writer。

normal boot 不 decrypt age、不读取 stable S 获取登录密码、不访问
repo ciphertext——只读 `/persist/system/accounts/<user>/password.hash`。
hash 不进 store/argv/log。

**历史教训**：早期独立 password-project writer 在替换 shadow hash 时
误用 `(cons hash (cdr fields))`（把 hash 写进 name 字段，正确应为
`(cons (car fields) (cons hash (cddr fields)))`），产生
`$6$…:!:` 坏行且 user 名丢失；同时结构测试用 passwd 格式断言 shadow
而假阳性通过。该 writer 已删除，credential 注入合并进唯一 projection
writer，测试改为真实执行并验证 shadow 行格式。

密码修改工作流（未来 `configctl passwd` 的规划语义，见 15.10）：在
可信环境生成新 hash → 更新 `user-password.hash.age` → 重新物化
persistent verifier → 下次 boot 的 projection 生效。运行期 `passwd`
只改 ephemeral `/etc/shadow`、reboot 后丢失，属 unsupported workflow。

### LUKS recovery credential

`luks-recovery.age` 经 stable S 解密后走 installer 既有 stdin 语义
（`disk-install apply --luks-secret`）；交互输入路径保留不变。
不把 recovery credential 持久化明文到 LUKS 卷内。

TPM 失败时的人工恢复：在可信环境用 master password 恢复 S → 解密
luks-recovery.age → 人工输入。

## 15.6 换机器 / 重装（Recoverability）

```text
clean repo + master password
  → secrets unlock（stable-identity.age）
  → 同一个 S
  → 全部 .age 无需 rekey 即可解密
  → secrets install 到新机器
```

不生成新 recipient、不修改 repository、不产生 host-specific
ciphertext。Git working tree 前后不变。

## 15.7 Reproducibility 定义

- **Reproducible**：同一 repo + channels lock + ciphertexts + public
  stable recipient → 相同的声明式 system closure / service graph。
- **External capability**：stable S 的私钥半部是 runtime machine
  cryptographic state，不是 build input。
- **Recoverable**：同一 repo + master password → 恢复 S → 恢复全部
  declarative secrets → 安装到任意新机器。

## 15.8 结构性 user profile 与 secrets 分离

`(guixcfg users user)` 的 `%primary-user` 是用户结构事实的唯一来源
（name/uid/groups/shell/home + password-secret 逻辑引用）；host 只
select。password hash、token 等经 secret reference 接入，不作为
Scheme 值出现在配置里。不允许“加密整个 user.scm 在 build 时解密”。

## 15.9 Consumer 接入

应用支持路径就直接配置路径：

```text
IdentityFile /run/guixcfg-secrets/users/user/github-key
```

必须传统位置时允许 Home 建 symlink（如 `~/.ssh/id_example` →
runtime 路径）；Home 只管理 symlink，不读取 secret 内容；plaintext
target 在 tmpfs /run。

## 15.10 Future Work（记录，不实现）

- session-bound user secret lifecycle（login-aware broker 直接解密到
  `$XDG_RUNTIME_DIR`，logout 即消失）；
- optional multiple trust domains；
- external encrypted-bootstrap-identity storage；
- secret rotation UX；
- Home preview/test tooling；greetd/desktop；
- hardware-backed identity（仅当未来威胁模型变化）；
- **login-critical vs ordinary secrets 分类（TODO）**：当前
  `interactive-secrets-ready` 由全部 `%vm-secrets`（含 test/普通应用
  secret）共同 provision——普通非关键 secret 失败会阻塞 interactive
  login。未来将 secrets 分为 login-critical 与 ordinary application
  两类，`interactive-secrets-ready` 只代表前者；
- **root Last Good / readiness 边界（TODO）**：`ephemeral-root-confirm`
  在 user-processes 后标记 boot ok / promote Last Good，可能先于真正
  interactive readiness（no usable login 但 root 被标 Last Good）。
  未来应与正确的 interactive readiness/health 语义对齐；
- **stable identity 离线攻击边界（TODO）**：见 15.0.1.1；
- **password rotation 正式入口（TODO）**：见 15.0.1.2。
