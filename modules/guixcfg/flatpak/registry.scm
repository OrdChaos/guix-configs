;;; Flatpak registry：纯 aggregation / lookup（docs/architecture/
;;; flatpak.md）。
;;;
;;; 本文件不包含任何应用的业务声明——应用事实全部在各
;;; applications/<name>.scm 的自包含 definition 里。registry 只做：
;;;   - 导入 definitions，构造 %flatpak-applications（Catalog）；
;;;   - 构造 %flatpak-selection（Selection：设备要哪些 logical
;;;     names——不复制 app 事实，resolution 由 model 的
;;;     flatpak-select-applications 做 catalog lookup）；
;;;   - 构造 %flatpak-remotes（identity/trust/transport 声明）；
;;;   - 模块加载时统一 fail-fast 校验（名字查重、remote 已知、
;;;     selection ⊆ catalog）。
;;;
;;; 新增应用 = 新建 applications/<name>.scm + 在 aggregation list
;;; 加一次 + 在 selection 加一次。不改 service/persistence/host。

(define-module (guixcfg flatpak registry)
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak applications qq) ; %flatpak-qq
               #:export (%flatpak-remotes
                         %flatpak-applications
                         %flatpak-selection))

;; Remote 声明（identity / trust / transport 分离）：
;;   identity  = 'flathub
;;   trust     = key-file "flathub.gpg"（本目录 vendored 公开
;;               keyring，Flathub 官方签名密钥——主密钥
;;               4184DD4D907A7CAE + 签名子密钥 562702E9E3ED7EE8；
;;               provenance = dl.flathub.org/repo/flathub.gpg，
;;               与镜像副本逐字节一致）
;;               维护检查点：主/子密钥均于 2027-06-14 过期——到期前
;;               Flathub 必然续期或轮换（发布新 key 文件）；届时
;;               更新本文件 + remote-replace 重新导入（轮换失败
;;               模式 = sync 报 summary 签名 "public key not found"）
;;   transport = SJTU 镜像裸 OSTree URL（镜像内容 = 官方仓库同副本，
;;               同一份已签名 summary，GPG 验证不变）
;; 换源 = 改 repository-url（+ 如需改 trust 则换 key-file），然后
;; tools/flatpak.scm remote-replace <name>（显式）。
(define %flatpak-remotes
  (list (flatpak-remote
         (name 'flathub)
         (repository-url "https://mirror.sjtu.edu.cn/flathub")
         (key-file "flathub.gpg")
         (comment "Flathub via SJTU mirror"))))

;; Catalog：已知 Flatpak 应用（纯聚合——定义在 applications/ 下）。
(define %flatpak-applications
  (list %flatpak-qq))

;; Selection：sync 应 ensure 的 logical names（desired lifecycle ≠
;; persistence lifecycle 的结构分离；未来 per-host 差异时在
;; hosts/*.scm 定义各自列表）。persistence 投影从 selection 派生：
;; 未选中的 app 不产生 persistence mount（其 definition 里的
;; persistence intent 随 selection 生效）。
(define %flatpak-selection
  '(qq))

;; fail-fast（模块加载即校验；apps/registry.scm 同款）。
(validate-flatpak-catalog! %flatpak-remotes %flatpak-applications)
(validate-flatpak-selection! %flatpak-selection %flatpak-applications)
