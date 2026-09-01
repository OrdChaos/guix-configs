# Accounts & Sessions

用户账户、`/etc/{passwd,group,shadow}`、登录 credential、readiness
DAG、PAM/elogind、login gate。

## 账户与登录数据流

```text
persistent credential verifier（/persist/system/accounts/<user>/password.hash）
    +
generation account topology（user-account/user-group 声明）
    |
    v
account databases projection（唯一 writer，guixcfg/system/accounts.scm）
    |  写库前内联 verifier 进 shadow password 字段
    |  写库后验证最终 shadow（user 存在、hash == verifier、非 locked）
    v
/etc/{passwd,group,shadow}
    |
    v
account-state-ready（只读 verify 服务 provision）
    |
    v
interactive-session-ready
    |
    v
login（greetd（tty1，图形桌面入口）/ mingetty（tty2-6 fallback）/ sshd）
    |
    v
PAM / elogind（session、/run/user/<uid>）
```

## 单写者模型

`/etc/{passwd,group,shadow}` 的唯一 authoritative writer 是
account databases projection（activation 阶段，纯 Scheme，无 flock
FFI——上游 `activate-users+groups` 的 flock 在 boot 环境失败会导致
库空，已由本投影取代）。

- interactive（非系统、非 root）用户的 credential 在写库前从
  persistent verifier 读入并校验；
- **fail-closed**：verifier 缺失/非法、user 不在拓扑、最终 shadow
  缺 user / password 为空/`!`/与 verifier 不符 → projection 抛错
  中止，不写任何文件，login 不开放；
- `account-state-ready` 由只读验证服务（`guixcfg-account-databases-
  verify`）在**验证最终 /etc/shadow** 后才 provision；该服务绝不写
  文件。

历史教训：早期独立 password-project writer 用 `(cons hash (cdr
fields))` 把 hash 写进 name 字段（产生 `$6$…:!:` 坏行、user 名
丢失），结构测试因用 passwd 格式断言 shadow 而假阳性通过。该
writer 已删除，credential 注入并入唯一投影 writer。

## 用户结构事实

`(guixcfg users user)` 的 `%primary-user` 是用户结构事实的唯一来源
（name/uid/groups/shell/home + password-secret 逻辑引用）；host 只
select。password hash 不进 evaluator/store。

## Readiness DAG

```text
file-systems
    ↓
persistent-state-ready（/persist/system、/persist/data-home、
    /var/guix、/gnu/store 在位）
    ↓                    ↓
account-state-ready   interactive-secrets-ready
    ↓                    ↓
    └────────┬───────────┘
             ↓
      user-processes
             │
       ┌─────┴──────┐
       ▼            ▼
    elogind    guix-home-user
       │            │
       ▼            ▼
 session-infra-ready   home-ready
       └───────┬───────┘
               ▼
      interactive-session-ready（纯 barrier，打开 login gate）
               ▼
            login
```

readiness 命名 capability；provision 前必须验证最终可观察状态
（fail-closed）。`interactive-session-ready` 是纯 join barrier，
依赖四个 prerequisite 全部成功，然后原子删除 login gate。

## Login gate

`/run/guixcfg/session-not-ready`：存在即拒绝普通 interactive 登录
（pam_nologin 语义，root 豁免是标准行为——保留 console recovery）。
gate 的 path / close / open / message 唯一 authority 是
`(guixcfg system session-gate)`——boot activation 关闭端
（session-gate-close-activation）、interactive-session-ready 打开端、
live reconfigure 关闭/打开端（session-gate-close!/open!，reconfigure
文案 `%session-gate-reconfigure-message`）、PAM 段全部引用该模块。
PAM 横切只作用于 login 与 sshd 的 account 段。

## PAM / elogind

- elogind 提供 login/session tracking、/run/user/<uid> 生命周期与
  XDG_RUNTIME_DIR。
- 系统层职责；Home/persistence 都不碰 runtime 目录。
- greetd（tty1）与 mingetty（tty2-6 fallback）的 shepherd
  requirement 都含 interactive-session-ready：`login:` 出现即
  barrier 已过（图形桌面链路见 `graphics.md`）。

## 未来

- root 的 Last Good readiness 边界：见 development/roadmap.md。
