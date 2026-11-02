;;; ElyPDF Flatpak application definition
;;; https://flatpark.org/apps/ely.zacharyzhang.office.pdf/

(define-module (guixcfg flatpak applications ely-pdf definition)
  #:use-module (guix gexp) ;local-file
  #:use-module (guixcfg flatpak model)
  #:export (%flatpak-ely-pdf))

(define %flatpak-ely-pdf
  (flatpak-application (name 'ely-pdf)
                       (id "ely.zacharyzhang.office.pdf")
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
