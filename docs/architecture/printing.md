# Printing

HP LaserJet 1020 的 CUPS 队列、foo2zjs 驱动和 USB firmware lifecycle。

## Owner 与范围

- **唯一 CUPS owner**：`(guixcfg system printing service)` 管理 CUPS 与
  declarative queue projection。`(guixcfg system printing laptop)` 是 Laptop
  的唯一 composition/inventory：它将型号模块导出的 queue facts 与 device
  services 一次性交给 `printing-services`，因此只有一个 cupsd instance。
- **型号 owner**：`(guixcfg system printing hp-laserjet-1020)` 只管理该型号的
  USB identity、PPD、firmware loader 与 udev rule，不创建 CUPS service。
- **host gating**：只有 Laptop host
  （`(guixcfg hosts lenovo-legion-y7000p)`）消费
  `%laptop-printing-services`。VM 不导入打印模块，因而没有 CUPS、foo2zjs
  或 HP firmware closure。
- **官方机制**：pinned Guix 的 `cups-service-type` 运行 cupsd 并将
  `foo2zjs` 加入其 ServerBin/DataDir union；本仓库不重写 CUPS。

## Firmware

LaserJet 1020 是 host-based printer，每次断电都会丢失 firmware。
`hp-laserjet-1020-firmware` 由 Virelith 提供：它固定下载 HP 官方 Windows
installer，提取唯一必要的 `hp1020.img`，再用 free `foo2zjs` 的
`arm2hpdl` 转换成 `sihp1020.dl`。Windows driver 本身不进入 output。

USB `03f0:2b17` 出现时，`80-hp-laserjet-1020-firmware.rules` 运行一个
store-backed `program-file`：短暂等待 USB settle，然后通过 CUPS 的 USB
backend 上传 `sihp1020.dl`。这是设备 lifecycle，不是 CUPS queue state；
它不依赖 cupsd 已启动。

## Queue Projection

`hp-laserjet-1020-queue` 是单一 queue inventory，声明：

- queue name：`hp-laserjet-1020`；
- URI：`usb://HP/LaserJet%201020`；
- PPD：foo2zjs 的 `HP-LaserJet_1020.ppd.gz`；
- default：`media-default=A4`。

`printing-queues` 是依赖 `cups` 的 Shepherd one-shot service。每次 boot
或 reconfigure 都调用 `lpadmin`，把上述 inventory 投影到运行中的 cupsd。
因此 `/etc/cups/printers.conf` 和 CUPS 复制的 PPD 是 ephemeral root 上的
derived state，绝不加入 persistent storage，也不存在第二个 queue writer。

## Queue Projection Authentication

`printing-queues` invokes `lpadmin` through `/var/run/cups/cups.sock`, never
through a TCP listener.  CUPS authenticates the root-owned one-shot using its
local authorization certificate or Unix-socket peer credentials, then applies
the normal `@SYSTEM` administrator policy.  Other local processes can prove
only their own identity and remain subject to that policy.

Keep Guix's default CUPS policy.  In particular, do not use `Satisfy any` to
work around authentication and do not add a network `Listen` directive unless
remote printing is an explicit, separately reviewed requirement.

## Filter Helpers

The HP PPD's legacy `foomatic-rip` filter invokes Poppler's `pdftops` CLI by
name.  The pinned Guix `cups-filters` package already has Poppler as an input,
but its wrapper omits Poppler's `bin` directory.  The printing service replaces
that package with a narrowly derived variant which prepends Poppler only to
`foomatic-rip`'s PATH.  It does not set CUPS's `PATH`, so the daemon retains
its ServerBin filter and backend lookup paths.

## Adding A Model

新增型号时，在 `modules/guixcfg/system/printing/<vendor>-<model>.scm` 导出：

- 一个或多个 `<printer-queue>`；
- 可选的 `%<model>-device-services`，仅用于 USB firmware、udev 或其他
  型号特有硬件 lifecycle。

然后只修改 `modules/guixcfg/system/printing/laptop.scm`，将 queues 加入其
唯一 `printing-services` 调用，并合并可选 device services。不得从型号模块
再次调用 `printing-services`，否则会产生第二个 CUPS owner。queue 名称、PPD、
driver packages 和默认选项都由 model module 声明；generic service 会校验 queue
名称唯一性并去重 driver packages。

可自由打印的 firmware/driver 使用 Guix package；厂商专有 firmware 或需从
官方 installer 提取的 blob 放在 Virelith 的 vendor/model package module（当前为
`(virelith packages hp-printers)`），由型号模块以 `file-append` 引用。这样
来源、hash、license 和转换逻辑属于 package channel，CUPS 配置仓库只保留硬件
integration 事实。

## 运行期验证

实机接上打印机后：

```sh
lsusb
lpinfo -v
lpstat -p -d
lp -d hp-laserjet-1020 /path/to/test.pdf
```

`lpinfo -v` 应确认 CUPS 实际发现的 URI 与 inventory 一致；若硬件报告的
URI 不同，应只修改型号模块中的 `%hp-laserjet-1020-device-uri`，不改
generic queue mechanism。`journalctl -b` 可用于检查 udev firmware loader
是否成功执行。

## 非目标

- 网络、IPP 或共享打印机；CUPS 仅保留 pinned service 的默认本地监听；
- 打印作业历史与配置持久化；
- 非 HP LaserJet 1020 型号。新型号应新增自己的 model module，并复用
  `printing-services` 与 `<printer-queue>`。
