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
        ↓ build
/gnu/store/<hash>-secret.age
        +
/persist/system/keys/age/host.key
        ↓ decrypt
/run/secrets/<name>
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
+ /run/secrets 中的秘密
        ↓
/run/mihomo/config.yaml
```

生成文件不持久化。

---

# 15. Secret 管理

## 15.1 密文位置

```text
~/guix-configs/
└── secrets/
    ├── hosts/
    │   ├── laptop/
    │   │   ├── mihomo-config.yaml.age
    │   │   ├── backup-key.age
    │   │   └── ...
    │   └── vm/
    │       └── ...
    └── recipients/
        ├── laptop.txt
        └── vm.txt
```

密文可以提交 Git，也可以进入 `/gnu/store`。

## 15.2 解密 identity

固定位置：

```text
/persist/system/keys/age/host.key
```

权限：

```text
root:root
0400
```

它：

- 不进入 Git；
- 不进入 `/gnu/store`；
- 不进入 root template；
- 位于 LUKS2 内；
- 必须有离线恢复副本。

## 15.3 明文位置

系统级：

```text
/run/secrets/
```

用户级：

```text
/run/user/<uid>/secrets/
```

明文 secret 不进入持久磁盘。

## 15.4 部署要求

解密过程必须：

```text
写入临时文件
→ 设置 owner/group/mode
→ 原子 rename 到最终路径
```

服务在 secret 成功生成后才能启动。
