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

启动和挂载优先使用这些语义名称，而不是安装时生成的 UUID。

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
  （normal / keep:N / previous:K / recovery）选择或从模板创建
  `@root-N`。
- `@root-template` 只读（ro=true），`@root-N` 可写。
- 状态文件：`/persist/system/root-generations/state.scm`
  （原子写，含 `.prev` 回退）。

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
