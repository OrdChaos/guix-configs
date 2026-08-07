# 系统配置：Host、软件与硬件


---

# 21. Host 模型

每台机器一个最终模块：

```text
modules/guixcfg/hosts/vm.scm
modules/guixcfg/hosts/laptop.scm
```

对应：

```scheme
(guixcfg hosts vm)
(guixcfg hosts laptop)
```

Host 负责：

```text
host-name
硬件
内核模块
内核参数
storage policy
boot 配置
mapped devices
file systems
系统 profiles
服务组合
最终 <operating-system>
```

Host 是最终组装点。

共享模块不能反向依赖 host。

当前不定义：

```text
<host-configuration>
全局 feature merge framework
大型 profile inheritance system
```

出现真实重复后再抽象。

---

# 22. Guix System 与 Guix Home

## 22.1 系统层

负责：

```text
内核
boot
文件系统
用户和组
系统服务
系统管理工具
硬件工具
Flatpak 基础设施
portal
configctl
```

## 22.2 用户层

Guix Home 负责：

```text
用户软件
shell
Git
终端
niri 配置
用户服务
桌面配置
Flatpak 应用声明
用户环境变量
```

System generation 与 Home generation 分开管理。

---

# 23. 软件分类

不能建立一个宣称包含“全部软件”的根级 `software/` 目录。

软件按生命周期分类。

## 23.1 系统级 Guix 软件

位置：

```text
modules/guixcfg/system/packages.scm
```

包括：

```text
configctl
flatpak
文件系统工具
恢复工具
硬件工具
所有用户需要的基础工具
```

服务自己依赖的软件尽量由 service 直接引用。

## 23.2 用户级 Guix 软件

位置：

```text
modules/guixcfg/home/packages.scm
```

或由 Home profiles 组合。

包括：

```text
普通 CLI
桌面应用
编辑器
媒体工具
日常开发辅助工具
```

## 23.3 项目专属工具链

放在项目自身：

```text
manifest.scm
channels.lock.scm
```

不放进全局用户软件列表。

## 23.4 Flatpak 应用

机制位于：

```text
modules/guixcfg/home/services/flatpak.scm
```

具体应用选择位于：

```text
modules/guixcfg/home/profiles/desktop.scm
```

不建立：

```text
software/
flatpak/
```

这样的根级目录。

---

# 24. 硬件与驱动

## 24.1 驱动是系统声明，不是安装程序

在 Guix System 中，“安装驱动”通常不是运行一个安装程序，而是把若干层加入最终 `<operating-system>`：

```text
内核
├── 内核自带模块
├── 外部内核模块
├── firmware
├── initrd 中需要的模块
├── 内核参数
├── udev 规则
├── 用户空间驱动库
└── 配套系统服务
```

`<operating-system>` 本身提供 `kernel`、`firmware` 和 `kernel-loadable-modules` 等字段，因此驱动属于系统声明，而不是安装后留在 `/usr` 中的不可追踪状态。

驱动配置完成后：

```text
修改 Scheme
→ system build
→ Git commit
→ system switch
```

新的内核、内核模块、firmware、用户空间库和服务作为一个 system generation 部署。旧 generation 保留原来的驱动组合，可以一起回滚。

### 五种情况

1. 内核自带驱动

例如 Intel `i915`、`iwlwifi`、USB HID、NVMe、常见声卡、大部分文件系统。通常不需要单独安装软件包，只需要：

- 选择包含该驱动的内核；
- 必要时让模块进入 initrd；
- 必要时指定内核参数；
- 提供设备所需 firmware。

2. Firmware

Firmware 不是内核模块，通过 `<operating-system>` 的 `firmware` 字段加入系统。

Laptop 需要非自由 firmware，因此使用 Nonguix 的标准 Linux 内核和 `linux-firmware`，而不是 Guix 默认的 Linux-libre。

3. 外部内核模块

例如 NVIDIA 专有内核模块、某些第三方 Wi-Fi 模块、ZFS、VirtualBox host module。模块必须被打包为与当前内核匹配的 Guix package，并通过 `kernel-loadable-modules` 或专用 service/transformation 集成。

不能直接运行 NVIDIA `.run` 安装器，因为它绕过 `/gnu/store`，修改可丢弃根目录，并破坏内核与驱动版本之间的声明关系。

4. 用户空间驱动

显卡不仅需要内核模块，还需要 OpenGL、EGL、Vulkan、GBM、VDPAU、OpenCL/CUDA 对应的用户空间库。

NVIDIA 尤其如此：只有内核模块并不足够，图形程序还必须使用 NVIDIA 对应的用户空间库，而不是普通 Mesa。

5. 服务、udev 和辅助程序

打印机、扫描仪、蓝牙设备、部分硬件传感器可能需要后台 daemon、udev rule、firmware upload helper、设备权限规则和过滤器。这些由 Guix service 或 package 提供。

## 24.2 显卡（Laptop）

Laptop 是 Intel UHD + NVIDIA RTX 4050 Laptop，使用混合显卡配置：

```text
Intel
    默认负责桌面和日常渲染

NVIDIA
    PRIME render offload
    游戏和重负载应用按需启动
```

### Intel 部分

Intel `i915` 驱动来自 Linux 内核。系统声明负责标准 Linux 内核、Intel firmware、Intel CPU microcode 和 `i915` 所需内核参数：

```scheme
(use-modules
 (nongnu packages linux)
 (nongnu system linux-initrd))

(operating-system
  (kernel linux)
  (initrd microcode-initrd)
  (firmware
   (cons* linux-firmware
          %base-firmware))
  ...)
```

### NVIDIA 部分

使用 Nonguix 推荐的 `nonguix-transformation-nvidia` 对最终 `<operating-system>` 做转换，而不是手工拼接旧版的 module、service、udev 和 Xorg 配置。该 transformation 处理系统侧 NVIDIA 模块、firmware、用户空间驱动以及相关系统配置；其内核模式设置（KMS）默认开启，而 KMS 是 Wayland 所需要的。

概念结构：

```scheme
(define %laptop-base-os
  (operating-system
    (kernel linux)
    (initrd microcode-initrd)
    (firmware
     (cons* linux-firmware
            %base-firmware))
    ...))

(define %laptop-os
  ((nonguix-transformation-nvidia
    #:dynamic-boost? #t)
   %laptop-base-os))

%laptop-os
```

桌面为 niri + greetd 纯 Wayland 会话，因此通常不需要让 transformation 配置 Xorg display manager；KMS 保持开启即可。

NVIDIA 专有模块是外部内核模块，在 Secure Boot 下必须签名，见第 16.5 节。

混合显卡应用通过 `prime-run`（由 Nonguix 的 `nvidia-prime` 提供）按需使用独显：

```bash
prime-run steam
prime-run gamescope -- <game>
```

### NVIDIA 应用包变体

某些程序需要 NVIDIA 专用变体或 Mesa 替换，例如 Steam、OBS、FFmpeg NVENC、部分 Vulkan/OpenGL 工具。Nonguix 通过 `replace-mesa`、`nvda` 以及若干 NVIDIA package variant 处理这一层。

用户软件列表不能简单地写：

```scheme
(list steam)
```

而应由一个共享辅助函数处理，例如：

```scheme
(define (nvidia-package package)
  (replace-mesa package))
```

或直接使用 Nonguix 提供的 `steam-nvidia`、`mpv-nvidia`、`obs-nvidia` 等变体。

具体哪些程序需要替换，应在 VM 和 Laptop 实机测试后确定，不无差别地转换整个 Home 软件集合。

## 24.3 打印机

打印机驱动和显卡驱动不是同一种东西。通常结构是：

```text
USB / 网络设备
      ↓
CUPS
      ↓
打印机描述和过滤器
      ↓
设备专属驱动
      ↓
打印数据
```

### 通用打印服务

使用 Guix 的 `cups-service-type`，`cups-configuration` 的 `extensions` 字段用于加入打印驱动和过滤器（默认扩展已包含 `cups-filters`、`foomatic-filters`、`hplip-minimal`、`brlaser`、`splix` 等）。

概念配置：

```scheme
(define %printing-services
  (list
   (service cups-service-type
            (cups-configuration
             (web-interface? #t)
             (extensions
              (list cups-filters
                    foomatic-filters
                    hplip-minimal
                    ...))))))
```

Laptop host 启用：

```scheme
(services
 (append %printing-services
         %other-services))
```

### HP LaserJet 1020

HP LaserJet 1020 通常需要 `foo2zjs` 系列的过滤器，并且该类打印机可能需要在连接或开机时向设备上传 firmware。

最终做法：

```text
personal-channel
└── foo2zjs package
    ├── 驱动/filter
    ├── PPD
    ├── firmware
    ├── firmware upload helper
    └── udev rules
```

然后在 `system/hardware/printing.scm` 中把它加入 CUPS extensions 和 udev rules。

项目规则：

> 优先使用频道中可用且经实机验证的 `foo2zjs`；若缺失或版本不可用，在 `personal-channel` 中维护已验证的 package、firmware 和 udev 规则。

禁止在系统安装完成后运行 `sudo make install` 安装打印驱动，因为它写入的文件：

- 不在 `/gnu/store`；
- 无法随 system generation 回滚；
- 可能在新的 root generation 中消失；
- 无法由空盘重建流程复现。

### 打印机队列

推荐声明式创建队列：在 printing 配置中声明队列名称、设备 URI、驱动/PPD、默认纸张和双面能力，由 activation 或 Shepherd one-shot service 在 CUPS 启动后幂等执行：

```bash
lpadmin ...
```

这样每个干净 root 都能重新生成打印机队列，不需要持久化 `/etc/cups/printers.conf`。

注意：Guix 的 `cups-service-type` 只管理 daemon 和 extensions，不提供声明式队列。上述 one-shot `lpadmin` 机制是本项目待验证实现：`lpadmin` 依赖 CUPS socket 就绪，其幂等性和启动顺序必须在 VM 阶段验证后才能作为正式方案。

备选模型是保留 CUPS 的命令式状态：若希望继续使用 CUPS Web UI 手动增删打印机，则把 CUPS 的必要可变状态放到 `/persist/system/cups`，再映射到 CUPS 使用的目录。但这种方式意味着实际队列可能偏离 Git 配置，恢复时只能恢复状态，而不是由声明重新生成。

因此：

```text
驱动和队列定义
    → guix-configs

打印任务和临时 spool
    → 可丢弃

确实需要保留的 CUPS 可变状态
    → /persist/system/cups
```

本地 HP 1020 队列声明式创建，不持久化 CUPS 配置。

## 24.4 目录落位

```text
modules/guixcfg/system/
└── hardware/
    ├── graphics.scm
    └── printing.scm
```

`system/hardware/graphics.scm` 负责：

- 标准 Linux 和 firmware；
- NVIDIA transformation；
- PRIME 支持；
- 与 GPU 有关的共享软件转换辅助函数。

`system/hardware/printing.scm` 负责：

- CUPS 服务和 extensions；
- 设备专属驱动（如 `foo2zjs`）和 udev 规则；
- 打印机队列声明。

`hosts/laptop.scm` 负责选择启用：

```text
host laptop
    ↓
启用 Intel + NVIDIA 硬件配置
    ↓
产生最终 operating-system
```

VM 不启用 NVIDIA 配置。

## 24.5 驱动更新流程

驱动没有单独的 `install-driver` 操作，跟随频道和系统配置更新。

NVIDIA 驱动更新：

```text
更新 Nonguix 锁定 revision
→ configctl system build
→ 测试构建和 VM
→ git commit
→ configctl system switch
→ 重启进入新 UKI
```

打印驱动更新：

```text
更新 personal-channel 中的 foo2zjs
→ 更新 guix-configs 的 personal-channel revision
→ system build
→ commit
→ system switch
```

最终边界：

```text
显卡、网卡、声卡等内核驱动
    → kernel / firmware / kernel modules

NVIDIA 用户空间库
    → Nonguix transformation 和 package transformation

打印机、扫描仪
    → 系统 service + driver/filter package + udev

所有驱动版本
    → channels.lock.scm 固定

所有正式安装
    → 已提交 Git commit
```

驱动不是安装到持久根目录中的额外文件，而是成为 Guix system generation 的组成部分：

```text
配置声明
→ kernel / firmware / module / service
→ /gnu/store
→ system generation
→ UKI
```

这保证内核、驱动、firmware 和用户空间库一起升级、一起回滚。

## 24.6 参考

- Guix `<operating-system>` 的 `kernel`、`firmware`、`kernel-loadable-modules` 字段：<https://guix.gnu.org/manual/en/html_node/operating_002dsystem-Reference.html>
- Nonguix：`nonguix-transformation-nvidia`、`nvidia-prime`、`replace-mesa`、标准 Linux 与 microcode initrd：<https://gitlab.com/nonguix/nonguix>
- Guix 打印服务 `cups-service-type` 与 `extensions`：<https://guix.gnu.org/manual/en/html_node/Printing-Services.html>
- Guix 事务式升级与 generation 回滚模型：<https://arxiv.org/abs/1305.4584>

---

# 25. Flatpak

## 25.1 系统职责

系统 desktop profile 提供：

```text
flatpak
xdg-desktop-portal
对应桌面 portal
必要的 XDG_DATA_DIRS 集成
```

## 25.2 Home service

位置：

```text
modules/guixcfg/home/services/flatpak.scm
```

负责：

```text
配置用户级 remote
安装缺失应用
检查实际状态
提供必要环境变量
```

## 25.3 应用声明

具体 Flatpak 应用放在：

```text
modules/guixcfg/home/profiles/desktop.scm
```

示意：

```scheme
(define %desktop-flatpaks
  (list
   (flatpak-application
    (remote "flathub")
    (id "com.github.tchx84.Flatseal")
    (branch "stable")
    (commit "...")))))
```

## 25.4 删除策略

默认：

```text
只安装缺失应用
不自动删除额外应用
```

Home service 可以报告：

```text
声明但未安装
已安装但未声明
```

移除必须显式执行并确认。

## 25.5 更新策略

`home switch` 不应无条件执行：

```text
flatpak update
```

Flatpak 更新必须显式进行并提交新的声明或 commit。

Flatpak 不属于 Guix 强可复现边界，因为远端可能清理旧 commit。

它属于：

```text
显式更新
可审计
外部滚动
弱长期归档保证
```

## 25.6 Flatpak 数据

用户 Flatpak installation 持久化为：

```text
/persist/data-app/flatpak
```

暴露到：

```text
~/.local/share/flatpak
```

---

# 26. Rust 工具链

不使用 rustup 作为主要工具链管理器。

原因：

- 绕过 Guix channel lock；
- 绕过 `/gnu/store`；
- 在用户 home 中维护独立工具链状态；
- 难以纳入系统可复现边界。

## 26.1 临时编译

Clone 普通 Rust 项目后：

```bash
guix shell \
  rust \
  pkg-config \
  gcc-toolchain \
  -- cargo build
```

按项目依赖追加库。

## 26.2 长期项目

项目中保存：

```text
Cargo.toml
Cargo.lock
manifest.scm
channels.lock.scm
```

编译：

```bash
guix time-machine \
  -C channels.lock.scm \
  -- shell \
  -m manifest.scm \
  -- cargo build
```

## 26.3 多版本

不同项目通过不同的：

```text
channels.lock.scm
manifest.scm
```

选择不同 Rust 版本。

多个版本可以同时存在于 `/gnu/store`。

## 26.4 特殊版本

Guix 中不存在的版本或 nightly：

```text
在 personal-channel 定义 package
```

不把 personal-channel 变成完整 rustup 镜像，只维护实际需要的版本。

## 26.5 全局工具

可以在 Guix Home 提供：

```text
rust-analyzer
cargo-audit
cargo-deny
cargo-edit
```

具体 `rustc`、Cargo 和项目依赖优先由项目环境提供。

---

# 27. niri 和其他公开配置

niri 配置源码：

```text
~/guix-configs/files/niri/config.kdl
```

Guix Home 部署后：

```text
~/.config/niri/config.kdl
    → /gnu/store/<hash>-niri-config.kdl
```

禁止：

```text
~/.config/niri/config.kdl
    → ~/guix-configs/files/niri/config.kdl
```

修改流程：

```text
修改 files/niri/config.kdl
→ configctl home build
→ 检查
→ git commit
→ configctl home switch
```

相同模式适用于：

```text
Git 配置
终端配置
shell 配置
编辑器静态配置
其他声明式 dotfiles
```

---

# 28. Mihomo

## 28.1 系统服务

Guix service：

```text
modules/guixcfg/services/mihomo.scm
```

使用 Shepherd，不依赖 systemd。

## 28.2 配置

公开模板进入：

```text
/gnu/store
```

整文件 secret 使用 age 解密到：

```text
/run/secrets/
```

运行时生成：

```text
/run/mihomo/config.yaml
```

Mihomo 读取该文件。

## 28.3 状态

可变状态放在：

```text
/persist/data-app/mihomo
```

## 28.4 控制

由独立：

```text
mihomo-remote
```

管理 API 和节点切换。
