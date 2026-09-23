# Offline ISO（Lenovo system closure）

本文定义并构建 Lenovo Legion Y7000P 的离线安装 ISO。它覆盖的边界是：
在联网环境构建 ISO 后，目标机从该 ISO 启动即可**断网**完成：

1. `blue install lenovo-legion-y7000p DEVICE`；
2. reboot 后的自动 Guix Home 激活；
3. `blue firstboot lenovo-legion-y7000p`（reconfigure + 固件 enrollment
   相位 1）；
4. reboot 后的 `blue enroll lenovo-legion-y7000p`（TPM enrollment）。

不覆盖（有意排除）：

- Flatpak 应用/runtime/游戏数据（当前 track-branch，无可审计的固定
  OSTree commit closure；需要单独做媒体内 OSTree snapshot）；
- Mihomo provider 在线订阅数据；
- Noctalia 插件仓库的后续运行时下载；
- 普通系统更新所需的新 substitute/channel 内容（ISO 只保证上述
  固定 checkout 的收敛路径离线）。

## ISO 内容

`modules/guixcfg/images/lenovo-installer.scm` 以 official
`installation-os` 为基础，并增加以下 GC roots / activation payload：

- 当前 pinned channel profile（`guix time-machine -C channels.lock.scm`
  的 profile store item）；
- 完整仓库 snapshot（含 `.git`；排除 `.blue-store`、`.zcode`、`vms`），
  activation 后位于 `/home/guest/guix-configs`，并兼容链接
  `/root/guix-configs`；
- Lenovo 目标 System + Home closure（包括 Nonguix kernel/firmware/
  microcode 与 NVIDIA runtime packages）；
- installer-only 工具：blue、git、ukify、openssl、efitools、
  sbsigntools（qemu 不属于安装器）。

启动时 activation 还会为 `guest` 与 `root` 预置 pinned inferior cache：
`/var/guix/profiles/per-user/<user>/inferiors/<key>` 指向 channel
profile。`guix time-machine` 对 full commit 的 cache hit 只要求该目录
存在，因此安装阶段不再访问 Git channel。

`blue install` 的 `system-init` 表达式在检测到唯一预置 root inferior
cache 时，会把该 channel profile 包进目标 OS 的 GC roots；安装事务随后
把同一 cache 复制到目标 `/var/guix/profiles/per-user/{root,<user>}`。
因此 firstboot/enroll 的 time-machine 在目标系统上也继续离线命中。

## 构建

构建 ISO 的机器需要联网（下载 substitutes/package sources/channel
metadata），并需要 Guix daemon 的 `TMPDIR=/var/tmp`（kernel 本地编译
临时空间政策见 `docs/operations/installation.md`）。Nonguix
kernel/firmware 无第三方 substitute，首次构建会本地编译；受控并行示例：

```bash
cd /path/to/guix-configs

# OS/initrd derivation 与机器 LUKS UUID 无关（UUID 是 initrd 运行时
# 从 ESP /EFI/Guix/luks-uuid 读取的事实，见 docs/architecture/boot.md），
# 因此构建 ISO 不需要 facts，安装时 guix system init 也零重建、零下载。
GUILE_LOAD_PATH="$PWD/modules" \
GUILE_LOAD_COMPILED_PATH="$PWD/modules" \
guix time-machine -C channels.lock.scm -- system image \
  --image-type=iso9660 \
  --cores=2 --max-jobs=1 \
  modules/guixcfg/images/lenovo-installer.scm
```

命令成功时输出 ISO 的 store 路径（例如 `/gnu/store/…-image.iso`）。
查看大小：

```bash
stat -c '%n %s bytes' /gnu/store/…-image.iso
```

> 安全预检使用 `guix build --dry-run` / `blue build-os -n`。不要为
> 了“只看 derivation”而对 system/image 使用会触发 package build 的
> probe 路径；`system build -d`/`system image -d` 在实际依赖未缓存时
> 也可能先构建输入（2026-09 实测）。

## 使用

在 Lenovo 目标机上以 UEFI 启动 ISO，然后以 `guest` 用户执行：

```bash
cd /home/guest/guix-configs

blue -n install lenovo-legion-y7000p /dev/nvme0n1
blue install lenovo-legion-y7000p /dev/nvme0n1

# 关机/重启进入已安装系统（安装完成不会自动 reboot）
cd ~/Projects/guix-configs
blue -n firstboot lenovo-legion-y7000p
blue firstboot lenovo-legion-y7000p

# reboot（Secure Boot 激活；LUKS 密码人工输入一次）
blue enroll lenovo-legion-y7000p
```

ISO 内已经包含 `blue`，不需要再运行 `guix time-machine ... shell -m
manifests/development.scm`。若从普通 Guix installer 而非本 ISO 启动，
则仍按 `installation.md` 的联网流程执行。

## 验收标准

- ISO 构建后，断网启动 Lenovo 目标机；
- `blue install` 阶段不出现 channel fetch/substitute download；
- 首次 boot 自动 Home 激活成功；
- `blue firstboot` 与 reboot 后 `blue enroll` 均不要求网络；
- 运行期联网数据（Mihomo provider/Noctalia plugins/Flatpak）允许另行
  在线获取，不作为本 ISO 的离线完成条件。
