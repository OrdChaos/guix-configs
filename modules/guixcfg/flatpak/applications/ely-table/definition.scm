;;; ElyTable Flatpak application definition
;;; https://flatpark.org/apps/ely.zacharyzhang.office.table/

(define-module (guixcfg flatpak applications ely-table definition)
  #:use-module (guix gexp) ;local-file
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-ely-table %ely-table-desktop-entry))

;; Flatpak exports 固定命名 <app-id>.desktop；XDG 默认关联策略消费。
(define %ely-table-desktop-entry
  "ely.zacharyzhang.office.table.desktop")

(define %flatpak-ely-table
  (flatpak-application (name 'ely-table)
                       (id "ely.zacharyzhang.office.table")
                       (remote 'flatpark)
                       (branch "stable")
                       (update-policy 'track-branch)
                       (override-policy 'external)
                       ;; 共享设置的首次初始化（MiSans / 14 px / 150%）：
                       ;; seed-once 只在该沙箱还没有 settings.json 时写入，
                       ;; 之后用户修改永久生效，仓库不再拥有该文件。
                       (seeds (list (list "data/ElyOffice/settings.json"
                                          (local-file
                                           "settings.seed.json"))))))
