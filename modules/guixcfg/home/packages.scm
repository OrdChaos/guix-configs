;;; Guix Home 的用户包集合（normal-user CLI tools + M2 Wayland
;;; desktop 用户会话包）。System/security tooling（cryptsetup、
;;; btrfs-progs、tpm2-tools、sbkeysync、efibootmgr）不属于 Home——
;;; 它们由 Guix System 拥有。桌面会话内服务（PipeWire、notification、
;;; polkit agent 等）作为用户包进入 profile，由 niri config 的
;;; spawn-at-startup 以用户身份启动（单一 owner = niri session）。

(define-module (guixcfg home packages)
               #:use-module (gnu packages admin)      ; tree
               #:use-module (gnu packages compression) ; unzip、zip
               #:use-module (gnu packages curl)    ; curl
               #:use-module (gnu packages file)    ; file
               #:use-module (gnu packages freedesktop) ; wl-clipboard
               #:use-module (gnu packages less)    ; less
               #:use-module (gnu packages linux)   ; pipewire、wireplumber
               #:use-module (gnu packages polkit)  ; polkit-gnome
               #:use-module (gnu packages terminals) ; foot
               #:use-module (gnu packages version-control) ; git
               #:use-module (gnu packages rust-apps) ; fd、ripgrep
               #:use-module (gnu packages wget)    ; wget
               #:use-module (gnu packages web)     ; jq
               #:use-module (gnu packages window-management) ; mako
               #:use-module (gnu packages xdisorg) ; fuzzel
               #:use-module (gnu packages xorg) ; xwayland-satellite
               #:export (%home-packages))

(define %home-packages
  (append
   (list git ripgrep fd tree jq curl wget unzip zip less file
         ;; M2 Wayland desktop 用户会话（GPU-neutral；docs/architecture/
         ;; graphics.md）
         foot fuzzel mako polkit-gnome
         pipewire wireplumber
         xwayland-satellite wl-clipboard)))
