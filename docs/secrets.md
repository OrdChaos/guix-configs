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

**为什么是 boot-time 注入而不是 install-only**（pinned Guix 源码 +
VM 实测，修正后架构第 5-8 条的决定性实验）：

- `user-account-password` 直接序列化进 activation gexp → 进 store；
- `passwd->shadow` 复用 `/etc/shadow` 已有条目（reconfigure 不覆盖，
  VM 实测确认）；
- 但 ephemeral root 下 `@root-template` 在 commit-root 时固化，而
  account activation 只在首次 boot 运行——template 的 `/etc/shadow`
  没有 install 期注入的 hash；每 boot `@root-N = snapshot(template)`
  → current-shadow 无该条目 → 回退 user-account-password（#f →
  locked）。实测：password=#f + reconfigure 后 hash 保留（reuse），
  reboot（ephemeral rebuild）后登录失效。

因此 `guixcfg-password-inject`（one-shot，file-systems+user-homes 后、
login 前）每 boot 把 install secret 的 hash 注入 ephemeral
`/etc/shadow`（读 shadow、替换该行、0600 原子 rename）。hash 不进
store/argv/log。

密码修改工作流（本轮定义的唯一官方路径）：在可信环境生成新 hash →
用 S 更新 `user-password.hash.age` → 部署生效（下次 boot 注入）。
运行期 `passwd` 产生的状态不持久（ephemeral），属 unsupported
workflow（不要留下两套 authoritative password state）。

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
- hardware-backed identity（仅当未来威胁模型变化）。
