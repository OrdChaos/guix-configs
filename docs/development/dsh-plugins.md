# DSH 插件声明式打包

DSH profile 是插件组合的边界。仓库管理插件集合、版本和配置；DSH 自己
拥有 sessions、storages、credentials、logs 等运行时状态。

## 两类插件

| 类型 | 来源 | 启用方式 |
|---|---|---|
| in-box bundle | DSH 包自身（`@deepseek-ai/dsh-base`、`dsh-web-app` 等） | 直接写进 profile 的 `dsh.profile.bundles` |
| 外部 npm bundle | 独立 npm 包，固定 tarball 和版本 | Virelith 描述包 + profile lockfile + `dsh-profile` artifact |

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
               #:lockfile (local-file "profiles/guix-web/pnpm-lock.yaml")
               #:patch (local-file "profiles/guix-web/cordis.patch.yml")
               #:node-modules-hash (base32 "...")))
```

`dsh-profile` 会：

- 按声明顺序生成 profile `package.json` 的 `dsh.profile.bundles`；
- 把外部描述包写成精确 `dependencies`；
- 生成 `pnpm-workspace.yaml`；
- 用固定 profile lockfile 在 profile 专属 root 安装一次；
- 校验每个外部 bundle 已安装且 manifest 仍声明 `dsh.bundle.patch`；
- 输出不可变 artifact：

```text
share/dsh/profiles/<name>/
  package.json
  pnpm-workspace.yaml
  cordis.patch.yml
  node_modules/
```

## Lockfile 与 hash

profile lockfile 是构建输入，必须提交到仓库。更新插件时：

1. 在临时目录生成与 `dsh-profile` 相同的 profile manifest；
2. 运行 `pnpm install --lockfile-only`；
3. 把 `pnpm-lock.yaml` 放回 `profiles/<name>/`；
4. 构建 profile artifact。首次使用临时 hash，Guix 会报告实际
   `node-modules-hash`，再回填并重建。

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

如果没有外部插件，继续使用当前静态 in-box profile 即可，不需要
`node_modules`。

## 边界

- 不执行 npm install script；带 native 构建的插件需要单独 package 和
  Guix-native 修补，不能走通用 tarball 工厂。
- 不使用 `latest`、不运行时查询 registry。
- 插件升级 = 改描述包版本/hash + 重新生成 lockfile + 更新
  `node-modules-hash` + reconfigure。
- Web Settings 写入 profile `cordis.patch.yml`，而仓库将其投影为只读
  store symlink；写入会 fail closed。需要长期保留的配置应写进仓库
  profile patch，然后 reconfigure。
