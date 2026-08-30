;;; 系统级软件：所有用户都需要的基础工具（docs/architecture/overview.md）。
;;; 服务自己依赖的软件由 service 直接引用，不放在这里。

(define-module (guixcfg system packages)
               #:use-module (gnu system)                     ; %base-packages
               #:use-module (gnu packages linux)             ; btrfs-progs（当前 master 在此导出）
               #:use-module (gnu packages cryptsetup)        ; cryptsetup
               #:use-module (gnu packages golang-crypto)     ; age
               #:use-module (gnu packages package-management) ; flatpak
               #:use-module (guixcfg fonts)                  ; %fonts（shared fact；Flatpak sandbox 字体投影）
               #:export (%system-packages))

(define %system-packages
  (append (list btrfs-progs       ; 子卷/快照管理（恢复时必需）
                cryptsetup        ; LUKS 维护（恢复时必需）
                age               ; secrets 解密（guixcfg-secrets-deploy
                                  ; 的运行时依赖；account projection 只
                                  ; 读 persistent hash，不调 age）
                flatpak)          ; Flatpak executable（overview.md 软件
                                  ; 分类：system 提供 executable，一切
                                  ; installation 走 --user scope；
                                  ; docs/architecture/flatpak.md）
          ;; 字体投影：pinned Guix flatpak 的 flatpak-fix-fonts-icons.patch
          ;; 只把 /run/current-system/profile/share/fonts 暴露进 sandbox
          ;; （Home profile 字体不可见）。同一份 (guixcfg fonts) 事实、
          ;; 零复制列表、无 system→home import（docs/architecture/
          ;; flatpak.md（fonts））。
          %fonts
          %base-packages))
