;;; Sunshine Flatpak application definition（Moonlight 串流主机；
;;; docs/architecture/flatpak.md（application model））。
;;;
;;; 选型理由：Sunshine 的 Linux 分发以 Flatpak 官方包为主（Flathub
;;; dev.lizardbyte.app.Sunshine），Guix/Nonguix 无对应包；niri 的
;;; 虚拟输出（PR #3800）可被 Sunshine 的 wlr 采集后端通过
;;; wlr-screencopy 捕获——Sunshine 的 WLR_EXPORT_DMABUF 标志实际由
;;; zwlr_screencopy_manager_v1 绑定置位，不依赖 zwlr-export-dmabuf。
;;;
;;; app-id/branch 以 Flathub 官方页面核实（branch=stable）。
;;;
;;; override policy：'external——上游 manifest 已含 --socket=wayland、
;;; --device=all（/dev/dri、/dev/uinput）与 --talk-name=
;;; org.freedesktop.Flatpak（prep-cmd 经 flatpak-spawn --host 调
;;; host 的 niri msg）；实机验证发现真正需要 delta 时再按 Flatseal
;;; 工作流改为 managed-overrides。
;;;
;;; persistence：默认 ~/.var/app/dev.lizardbyte.app.Sunshine 由 ID
;;; 推导（service 投影，无需在此声明）。
;;;
;;; seeds：首次初始化写入 config/sunshine/sunshine.conf（seed-once）：
;;; capture=wlr 让 Sunshine 走 niri 的 screencopy（该键不在普通 UI
;;; 里），output_name=virtual 与 apps/niri 的全局虚拟输出同名；不
;;; seed apps.json——由 Sunshine 首次启动生成默认 Desktop app。编码器
;;; 由 Sunshine 运行时选择（Intel 走 vaapi，NVIDIA 走 nvenc），不在
;;; seed 里硬编码。

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
