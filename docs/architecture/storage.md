# Storage Architecture

磁盘布局、固定命名、持久子卷与 root generation。安装命令在
`operations/installation.md`。

## 固定命名事实

项目事实（直接写进实现，不做配置项）：

```text
GPT PARTLABEL    esp / system
GPT typecode     EF00（ESP）/ 8309（Linux LUKS）
VFAT label       ESP
Btrfs label      rootfs
LUKS label        cryptroot
mapper            /dev/mapper/cryptroot
```

启动和挂载优先使用这些语义名称，而不是安装时生成的设备路径。
LUKS 解锁的权威身份仍是 LUKS UUID：它不编入 OS/initrd
derivation，而是安装时写入 ESP `/EFI/Guix/luks-uuid`（写侧还有
esp-uuid activation 的迁移补写），initrd 运行时读取后按 UUID
扫盘匹配 LUKS 头（docs/architecture/boot.md）。

## 磁盘布局

```text
GPT
├── ESP（2–4 GiB，VFAT，partlabel=esp）
└── system（Linux LUKS2，partlabel=system）
    └── cryptroot（Btrfs 顶层 subvolid=5）
        ├── @persist-gnu-store    → /gnu/store
        ├── @persist-var-guix     → /var/guix（init 后收养，安装期不挂）
        ├── @persist-system       → /persist/system
        ├── @persist-data-app     → /persist/data-app（compress=zstd）
        ├── @persist-data-home    → /persist/data-home（compress=zstd）
        ├── @persist-data-nobackup→ /persist/data-nobackup（compress=zstd）
        ├── @persist-swap         → swapfile（4 GiB，NOCOW）
        ├── @persist-snapshots    → 本地快照
        ├── @root-template        → 只读模板
        └── @root-0..N            → root generations
```

`/boot` 不持久化：bootloader 状态（UKI/Limine）全部在 ESP 上。

## Root generation

- `@root-installing` → 安装期根 → commit 后 rename 为 `@root-0`，
  同时发布只读 `@root-template`。
- 每次 boot 由 initrd 读 `state.scm`，按 `rootmode=` 参数
  （normal / recovery）选择或从模板创建 `@root-N`。公开 boot
  model 只有 Normal / Recovery；历史 @root 不作为菜单项
  （previous:K / keep:N 选择器已删除，无法识别的值 fail closed）。
- `@root-template` 只读（ro=true），`@root-N` 可写。
- 状态文件：`/persist/system/root-generations/state.scm`
  （原子写，含 `.prev` 回退）。

**两条正交的 generation 轴**：

```text
Btrfs 轴   @root-N 子卷（磁盘根快照）
           → ephemeral-root-cleanup activation（自动，按 keep-root-generations）
Guix 轴    /var/guix/profiles/system-N-link（声明式 system generation）
           → blue gc（显式入口 + reconfigure 后自动，按同一 policy）
```

两轴共用保留算法 `(guixcfg storage root-generation)` 的
`generations-to-delete*` 与同一 host policy（`keep-root-generations`）：
保留 current、last-good，再保留最新 N 个。Guix 轴经
`(guixcfg system system-generations)` 决策、`tools/gc-cli.scm` 执行
（`guix package -p <system-profile> --delete-generations=...`），细节
与原因见 `operations/reconfigure.md`。last-good 的 Guix GC root 由
boot-state/recovery 维护。

Guix 轴只删 generation（移除 GC root），**不运行 `guix gc`**：删除
generation 不释放 store 空间；有意不自动 `guix gc`（它是全 store 级，
会连带回收 on-demand store 内容，如 rust-toolchain 代理 realize 的
toolchain）。store 空间由操作者显式回收。

## 持久子卷

固定的 8 个持久子卷；除 `/gnu/store` 和 `/var/guix` 外挂载点都在
`/persist` 下（见 `architecture/persistence.md` 的 inventory）。

## Swap

`@persist-swap` 子卷内的 swapfile，4 GiB、NOCOW、不压缩、预分配。

## Mount topology

```text
cryptroot
├── subvol=@persist-*   → /persist/*、/gnu/store、/var/guix
├── subvol=@root-N      → /selected-root → bind → /
└── ESP                 → /efi
```

根是 bind-mount（`/selected-root` → `/`），由 boot-system 处理。
