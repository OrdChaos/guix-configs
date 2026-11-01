# DSH 插件声明式打包

DSH profile 是插件组合的边界。仓库管理插件集合、版本和配置；DSH 自己
拥有 sessions、storages、credentials、logs 等运行时状态。

## 两类插件

| 类型 | 来源 | 启用方式 |
|---|---|---|
| in-box bundle | DSH 包自身（`@deepseek-ai/dsh-base`、`dsh-web-app` 等） | 直接写进 profile 的 `dsh.profile.bundles` |
| 外部 npm bundle | 独立 npm 包，固定 tarball 和版本 | Virelith 描述包 + profile `specs-hash` + `dsh-profile` artifact |

官方可选插件如果随 DSH 安装分发（例如
`@deepseek-ai/dsh-experimental-auto-review`），也可以直接加入 bundle
列表，不需要 npm 安装；只有不在安装内的第三方插件才需要外部闭包。

## 外部插件描述包

Virelith 的 `(virelith packages dsh-bundles)` 提供：

```scheme
(dsh-npm-bundle "@scope/plugin"
                "1.2.3"
                (base32 "<npm tarball sha256>"))
```

它只做三件事：

1. 从固定 npm tarball URL 取包；
2. 校验 `package.json` 的 name/version；
3. 校验 `dsh.bundle.patch` 是包内相对路径且文件存在。

它**不安装依赖闭包**。依赖解析必须在 profile 层统一完成。

tarball hash 的获取方式：

```sh
curl -fL -o /tmp/plugin.tgz \
  https://registry.npmjs.org/@scope/plugin/-/plugin-1.2.3.tgz
guix hash /tmp/plugin.tgz
```

## Profile artifact

`(virelith packages dsh-profiles)` 的 `dsh-profile` 接收有序 bundle 列表：

```scheme
#:use-module (virelith packages dsh-bundles)
#:use-module (virelith packages dsh-profiles)

(define %my-plugin
  (dsh-npm-bundle "@scope/plugin" "1.2.3" (base32 "...")))

(define %my-profile
  (dsh-profile "guix-web"
               #:bundles (list "@deepseek-ai/dsh-base"
                               "@deepseek-ai/dsh-web-app"
                               %my-plugin)
               #:patch (local-file "profiles/guix-web/cordis.patch.yml")
               #:specs-hash (base32 "...")))
```

`dsh-profile` 会：

- 按声明顺序生成 profile `package.json` 的 `dsh.profile.bundles`；
- 把外部描述包写成精确 `dependencies`；
- 生成 `pnpm-workspace.yaml`；
- 有外部 bundle 时，在 profile 专属 root 用 pnpm 解析一次闭包；
- 校验每个外部 bundle 已安装且 manifest 仍声明 `dsh.bundle.patch`；
- 输出不可变 artifact：

```text
share/dsh/profiles/<name>/
  package.json
  pnpm-workspace.yaml
  cordis.patch.yml
  node_modules/          # 仅当存在外部 bundle
```

只有 in-box bundle 时，`node_modules` 整段不存在，pnpm 完全不会被调用。
`#:specs-hash` 也只在存在外部 bundle 时必填；缺失会 fail closed。

## specs-hash 与升级

仓库**不提交 pnpm lockfile**。外部依赖闭包由 `pnpm-closure` 在构建期
解析成 fixed-output；`#:specs-hash` 是这个闭包的递归 sha256，因而同时
固定了顶层版本和所有 transitive dependencies。

首次启用或升级插件时：

1. 改描述包版本和 npm tarball hash；
2. 先填一个临时 `#:specs-hash` 并构建 profile；
3. Guix 会报告实际 hash；把它回填到 `#:specs-hash`；
4. 重新构建 profile artifact，再 reconfigure。

`pnpm-closure` 会把本次解析生成的 `pnpm-lock.yaml` 留在 store artifact
内供检查，但它不是配置仓库输入；依赖闭包只由 `specs-hash` 固定。

profile root 由 `dsh-profile-default-root` 生成，必须保持稳定；pnpm shim
会嵌入该路径，artifact 构建时再改写到最终 store 路径。

## app 接线

外部插件进入 app 时，profile 的 `node_modules` 和其他 repo-owned 文件
都走 `home-files-service-type` 的 store symlink：

```scheme
(simple-service 'dsh-profile
                home-files-service-type
                `((".local/share/dsh/profiles/guix-web/node_modules"
                   ,(file-append %my-profile
                                 "/share/dsh/profiles/guix-web/node_modules"))))
```

Home generation 切换时 symlink-manager 负责把链接更新到新的 artifact；
不需要 activation 时复制目录或维护自定义 symlink kind。

当前 `apps/dsh` 已按此接线：`apps/dsh/profiles.scm` 定义
`%dsh-guix-web-profile`，definition 把 artifact 的 package.json、
pnpm-workspace.yaml、cordis.patch.yml 经 home-files 投影。当前只有
in-box bundle，因此没有 node_modules；`%dsh-guix-web-external?` 为真时
definition 才会额外投影 node_modules。加入外部描述包后，把重算得到的
hash 填进 `%dsh-guix-web-specs-hash` 即可。

## 边界

- 不执行 npm install script；带 native 构建的插件需要单独 package 和
  Guix-native 修补，不能走通用 tarball 工厂。
- 不使用 `latest`、不运行时查询 registry。
- 插件升级 = 改描述包版本/hash + 重算 `specs-hash` + reconfigure。
- Web Settings 写入 profile `cordis.patch.yml`，而仓库将其投影为只读
  store symlink；写入会 fail closed。需要长期保留的配置应写进仓库
  profile patch，然后 reconfigure。
