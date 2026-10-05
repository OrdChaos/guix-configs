;;; 系统级软件：所有用户都需要的基础工具（docs/architecture/overview.md）。
;;; 服务自己依赖的软件由 service 直接引用，不放在这里。

(define-module (guixcfg system packages)
  #:use-module (gnu system) ;%base-packages
  #:use-module (gnu packages linux) ;btrfs-progs（当前 master 在此导出）
  #:use-module (gnu packages cryptsetup) ;cryptsetup
  #:use-module (gnu packages golang-crypto) ;age
  #:use-module (gnu packages package-management) ;flatpak
  #:use-module (gnu packages efi) ;efitools/sbsigntools（blue enroll 固件注册）
  #:use-module (guixcfg fonts model) ;%fonts（shared fact；系统/greeter/Flatpak）
  #:export (%system-packages))

(define %system-packages
  (append (list btrfs-progs ;子卷/快照管理（恢复时必需）
                cryptsetup ;LUKS 维护（恢复时必需）
                ntfs-3g ;NTFS 读写（udisks 只使用系统 profile
                ;; 里的 mount 工具——可移动 NTFS 介质的用户态驱动与
                ;; ntfsfix 等修复工具；内核 ntfs3 之外的必要补充，
                ;; Guix 手册（udisks-service-type））
                age ;secrets 解密（guixcfg-secrets-deploy
                ;; 的运行时依赖；account projection 只
                ;; 读 persistent hash，不调 age）
                flatpak ;Flatpak executable（overview.md 软件
                ;; 分类：system 提供 executable，一切
                ;; installation 走 --user scope；
                ;; docs/architecture/flatpak.md）
                sbsigntools ;sbsign：UKI signing runtime
                efitools) ;efi-updatevar：Setup Mode enrollment
          ;; 固件注册执行器（目标系统离线可用——不依赖
          ;; LiveCD manifest / channel fetch；
          ;; docs/architecture/boot.md（Secure Boot））
          ;; 字体进 system profile（docs/architecture/flatpak.md（fonts））：
          ;;   - greeter 以系统用户运行、无 Home，经 XDG_DATA_DIRS 的
          ;;     /run/current-system/profile/share 取字体（上游 GDM 同
          ;;     机制——gnu/services/xorg.scm 注释 "use fonts installed
          ;;     in it"）；
          ;;   - Flatpak 由 pinned Guix 的 flatpak-fix-fonts-icons.patch
          ;;     把 /run/current-system/profile/share/fonts 及其 store 闭包
          ;;     绑进沙箱（/run/host/fonts）。
          ;; 用户会话/桌面应用另由 Home profile 的同一份 %fonts 提供。
          %fonts
          %base-packages))
