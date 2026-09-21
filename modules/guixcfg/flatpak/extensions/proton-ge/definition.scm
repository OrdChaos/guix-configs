;;; Proton-GE compatibility tool extension definition（Flatpak；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; com.valvesoftware.Steam.CompatibilityTool.Proton-GE：Steam
;;; Flatpak 的 app extension（disable sandbox 的社区 Proton-GE
;;; 构建）。用途（上游 README）：
;;;   - 使 Flatpak gamescope 可用于 Windows 游戏（官方 Proton
;;;     的嵌套 Pressure Vessel 与 Flatpak gamescope 不兼容）；
;;;   - 随 flatpak update 自动更新 GE-Proton。
;;;
;;; 使用方式（mutable user state，不属本声明）：Steam 游戏
;;; 属性 → Compatibility → 选 "GE-ProtonVERSION# (Flatpak)"。
;;; 不需要 gamescope 的游戏继续用官方 Proton。
;;;
;;; 已知 cons（上游 README 明示）：更新可能破坏个别游戏兼容；
;;; 同时只能装一个 GE 版本；回退需 pin commit。

(define-module (guixcfg flatpak extensions proton-ge definition)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-extension-proton-ge))

(define %flatpak-extension-proton-ge
  (flatpak-extension
   (name 'proton-ge)
   (id "com.valvesoftware.Steam.CompatibilityTool.Proton-GE")
   (remote 'flathub)
   (branch "stable")
   (update-policy 'track-branch)))
