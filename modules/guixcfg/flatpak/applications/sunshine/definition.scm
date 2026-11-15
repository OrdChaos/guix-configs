;;; Sunshine Flatpak application definition（Moonlight 串流主机；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; 选型理由：Sunshine 的 Linux 分发以 Flatpak 官方包为主（Flathub
;;; dev.lizardbyte.app.Sunshine），Guix/Nonguix 无对应包。
;;;
;;; 采集方式（2026-11 实机结论）：Flatpak 1.16+ 在 compositor 支持
;;; wp-security-context-v1 时会为 app 创建带 security context 的
;;; Wayland socket；niri 把这类 client 标记为 restricted 并隐藏
;;; zwlr_screencopy_manager_v1（Sunshine 的 wlr 后端依赖它，源码里
;;; WLR_EXPORT_DMABUF 枚举实际由 screencopy bind 置位）。因此
;;; Flatpak 版不能用 capture=wlr；只能走 portal（Sunshine 的
;;; portalgrab 在 RemoteDesktop 不可用时回退 ScreenCast-only，
;;; niri 实现 org.gnome.Mutter.ScreenCast）。wlr-screencopy 的
;;; 直接采集（含 output_name 选择）只对非 Flatpak 的 Sunshine 可用。
;;;
;;; app-id/branch 以 Flathub 官方页面核实（branch=stable）。
;;;
;;; override policy：'external——上游 manifest 已含 --socket=wayland、
;;; --device=all（/dev/dri、/dev/uinput）、--filesystem=xdg-run/
;;; pipewire-0 与 --talk-name=org.freedesktop.Flatpak；portal 采集
;;; 不需要额外 override。实机验证发现真正需要 delta 时再按 Flatseal
;;; 工作流改为 managed-overrides。
;;;
;;; persistence：默认 ~/.var/app/dev.lizardbyte.app.Sunshine 由 ID
;;; 推导（service 投影，无需在此声明）。
;;;
;;; seeds：首次初始化写入 config/sunshine/sunshine.conf（seed-once）：
;;; capture=portal 是 Flatpak 下唯一可行的采集方式（见上）；
;;; output_name 在 portal 路径下不参与选择（由 portal picker/
;;; restore token 决定），保留以兼容将来切回非 Flatpak 的 wlr 后端。
;;; 不 seed apps.json——由 Sunshine 首次启动生成默认 Desktop app。

(define-module (guixcfg flatpak applications sunshine definition)
  #:use-module (guix gexp) ;local-file
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-sunshine))

(define %flatpak-sunshine
  (flatpak-application (name 'sunshine)
                       (id "dev.lizardbyte.app.Sunshine")
                       (remote 'flathub)
                       (branch "stable")
                       (update-policy 'track-branch)
                       (override-policy 'external)
                       (seeds (list (list "config/sunshine/sunshine.conf"
                                          (local-file "sunshine.conf"
                                                      "sunshine-flatpak-sunshine.conf"))))))
