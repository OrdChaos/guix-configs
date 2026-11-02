# DSH 插件声明式打包

DSH profile 是插件组合的边界。仓库管理插件集合、版本和配置；DSH 自己
拥有 sessions、storages、credentials、logs 等运行时状态。

## 目录结构

```text
modules/guixcfg/apps/dsh/
  extensions.scm          # 插件注册表（显式登记）
  extensions/
    base.scm              # @deepseek-ai/dsh-base
    web-app.scm           # @deepseek-ai/dsh-web-app
    tui.scm               # @deepseek-harness-tui/dsh-tui
  profiles.scm            # profile 注册表（显式登记）
  profiles/
    web.scm               # base + web-app
    tui.scm               # base + tui
  definition.scm
```

`extensions/` 下每个文件导出一个 dsh-profile 可接受的 bundle：in-box
bundle 是字符串，外部 npm bundle 是 `dsh-npm-bundle` 描述包。新增插件：

1. 新建 `extensions/<key>.scm`；
2. 在 `extensions.scm` 的 `%dsh-extensions` 登记；
3. 升级时只改对应文件的版本/tarball hash。

`%dsh-base-extensions` 是所有 profile 的公共层，当前包含
`@deepseek-ai/dsh-base` 与实验性的
`@deepseek-ai/dsh-experimental-auto-review`。profile 只能从注册表中选额外
插件：

```scheme
(dsh-extensions-for-profile '(web-app))
;; => base + auto-review + web-app
```

未知 key、重复 key 在求值期 fail closed。

## 两类插件

| 类型 | 来源 | 启用方式 |
|---|---|---|
| in-box bundle | DSH 包自身 | 直接写进注册表，值为 bundle 名字符串 |
| 外部 npm bundle | 独立 npm 包 | `dsh-npm-bundle` 固定 tarball，由 profile 解析闭包 |

外部描述包只做三件事：

1. 从固定 npm tarball URL 取包；
2. 校验 `package.json` 的 name/version；
3. 校验 `dsh.bundle.patch` 是包内相对路径且文件存在。

它**不安装依赖闭包**；依赖解析在 profile 层完成。

tarball hash：

```sh
curl -fL -o /tmp/plugin.tgz \
  https://registry.npmjs.org/@scope/plugin/-/plugin-1.2.3.tgz
guix hash /tmp/plugin.tgz
```

## Profile

`profiles/<name>.scm` 导出一个 `dsh-profile` artifact，并在
`profiles.scm` 登记。当前 profile：

- `web`：base + `@deepseek-ai/dsh-web-app`，启动命令 `dsh web`。
- `tui`：base + `@deepseek-harness-tui/dsh-tui`，启动命令
  `dsh --profile tui`。

两者共享同一个 `$DSH_HOME`、sessions 和 credentials；只是前端不同。
profile 是 pnpm 依赖解析边界，外部 bundle 使用 `specs-hash` 固定整个闭包：

```scheme
(dsh-profile "tui"
             #:bundles (dsh-extensions-for-profile '(tui))
             #:patch (plain-file "dsh-tui-cordis.patch.yml" "[]\n")
             ;; dsh-TUI resolves DSH peers from a sibling @deepseek-ai/dsh.
             #:auto-install-peers? #t
             #:extra-dependencies
             '(("@deepseek-ai/dsh" . "0.2.1-rc.5"))
             #:bundle-sources (dsh-extension-sources '(tui))
             #:specs-hash (base32 "..."))
```

`dsh-profile` 会生成 `dsh.profile.bundles`、依赖、`pnpm-workspace.yaml`，
有外部 bundle 时调用 pnpm 解析闭包，并校验每个外部 bundle 的 manifest。
外部插件可以在 `extensions/<name>.scm` 中继承 `dsh-npm-bundle`，用 Guix
package phases 直接 patch 安装后的插件内容（与 VS Code 扩展的 patch 形式
相同）。profile 通过 `#:bundle-sources` 消费这个已 patch 的 package，而不是
从 registry 重新安装原包。仓库不提交 pnpm lockfile，闭包由 `specs-hash`
固定。

首次启用/升级外部插件：

1. 改描述包版本和 tarball hash；
2. 先填临时 `#:specs-hash` 构建；
3. Guix 报告实际 hash，回填；
4. 重建 profile 并 reconfigure。

profile root 由 `dsh-profile-default-root` 生成，必须稳定；pnpm shim 会
嵌入该路径，artifact 构建时再改写。

## DSH TUI

`tui` 使用 dsh-TUI 作为声明式 profile 的前端，不安装独立桌面 runtime。
公共插件组包含实验性 Auto review；启用后 Web 和 dsh-TUI 的 `/permission`
都会出现 `Auto review`（`auto`）选项，选择后每个工具调用先由当前模型审查。
`extensions/tui.scm` 继承 `dsh-npm-bundle`，在 package build phase 中把
TUI 偏好目录从 `~/.dsh-tui` patch 到：

```text
$HOME/.local/share/dsh-tui
```


`definition.scm` 设置 `DSH_TUI_DATA_DIR` 并增加 persistence：

```text
/persist/data-app/dsh-tui/data -> ~/.local/share/dsh-tui
```

已有 `~/.dsh-tui` 数据在首次切换到新路径前需要手动迁移：

```sh
mkdir -p ~/.local/share/dsh-tui
mv ~/.dsh-tui/* ~/.local/share/dsh-tui/
rmdir ~/.dsh-tui
```

VS Code 集成扩展 `baobaolaodie.dsh-tui-vscode` 同步 patch 到同一路径，
`apps/vscode/settings.json` 指向声明式 `tui` profile：

```json
"dsh-tui-vscode.command": "/home/ordchaos/.guix-home/profile/bin/dsh",
"dsh-tui-vscode.extraArgs": ["--profile", "tui"],
"dsh-tui-vscode.dshHome": "/home/ordchaos/.local/share/dsh"
```

## app 接线

`definition.scm` 遍历 `%dsh-profiles`，把每个 profile artifact 的
`package.json`、`pnpm-workspace.yaml`、`cordis.patch.yml`（有外部插件时
还有 `node_modules`）经 `home-files-service-type` 投影到：

```text
~/.local/share/dsh/profiles/<profile>/
```

Home generation 切换时 symlink-manager 更新链接；repo-owned 文件是只读
store symlink，DSH Settings 写 profile patch 会 fail closed。配置变更应写
进仓库 profile，再 reconfigure。

## 边界

- 不执行 npm install script；带 native 构建的插件需要单独 Guix package。
- 不使用 `latest`、不运行时查询 registry。
- 插件升级 = 改描述包版本/hash + 重算 `specs-hash` + reconfigure。
- 外部 package patch 只用于行为/路径修正，不能绕过闭包解析。
