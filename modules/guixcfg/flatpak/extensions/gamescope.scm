;;; Gamescope Vulkan layer extension definition（Flatpak；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; org.freedesktop.Platform.VulkanLayer.gamescope：runtime
;;; extension，挂载于 /usr/lib/extensions/vulkan/gamescope
;;; （executable 在 .../bin）。消费方（flathub steam 的
;;; steam_wrapper、AAGL 的 wrapper）各自把该 bin 目录加入
;;; PATH——用户侧无需手动 PATH（上游 README 明确不建议
;;; --env=PATH 覆盖）。
;;;
;;; branch 与消费方 runtime 的底层 Freedesktop ABI 绑定：
;;; steam 当前 = org.freedesktop.Platform 25.08，故
;;; extension branch "25.08"。flathub 该 extension 提供
;;; 22.08–26.08 分支；runtime 大版本迁移（steam 升 26.08）
;;; 时同步换 branch——这里是唯一事实源，升级点见
;;; docs/architecture/flatpak.md。
;;;
;;; 已知边界（上游 issue 记录，非本仓库责任）：
;;;   - 与官方 Proton（嵌套 Pressure Vessel）不兼容——需要
;;;     gamescope 的游戏配合 proton-ge extension 使用；
;;;   - gamescope --steam 参数有黑屏报告（flathub gamescope
;;;     issue #483）——launch options 不用 --steam。

(define-module (guixcfg flatpak extensions gamescope)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-extension-gamescope))

(define %flatpak-extension-gamescope
  (flatpak-extension
   (name 'gamescope)
   (id "org.freedesktop.Platform.VulkanLayer.gamescope")
   (remote 'flathub)
   (branch "25.08")
   (update-policy 'track-branch)))
