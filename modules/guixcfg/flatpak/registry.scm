;;; Flatpak registry：纯 aggregation / lookup（docs/architecture/
;;; flatpak.md）。
;;;
;;; 本文件不包含任何应用的业务声明——应用事实全部在各
;;; applications/<name>/definition.scm 的自包含 definition 里。registry 只做：
;;;   - 导入 definitions，构造 %flatpak-applications（Catalog）；
;;;   - 构造 %flatpak-selection（Selection：全局用户软件 policy——
;;;     每台设备都安装这些 logical names，不复制 app 事实，resolution
;;;     由 model 的 flatpak-select-applications 做 catalog lookup）；
;;;   - 构造 %flatpak-remotes（identity / descriptor authority /
;;;     transport 声明）；
;;;   - 模块加载时统一 fail-fast 校验（名字查重、remote 已知、
;;;     selection ⊆ catalog）。
;;;
;;; 新增应用 = 新建 applications/<name>/definition.scm + 在 aggregation list
;;; 加一次 + 在 selection 加一次。不改 service/persistence/host。
;;; 新增 remote = 在此加一个 <flatpak-remote> 记录（+ 引用它的 app
;;; definition 写 remote name）——无 key 文件、无 descriptor 文件、
;;; 无 per-remote 代码分支。

(define-module (guixcfg flatpak registry)
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak applications qq definition)
               #:use-module (guixcfg flatpak applications wechat definition)
               #:use-module (guixcfg flatpak applications aagl definition)
               #:use-module (guixcfg flatpak applications steam definition)
               #:use-module (guixcfg flatpak extensions gamescope definition)
               #:use-module (guixcfg flatpak extensions proton-ge definition)
               #:export (%flatpak-remotes
                         %flatpak-applications
                         %flatpak-selection
                         %flatpak-extensions
                         %flatpak-extension-selection))

;; Remote 声明（identity / bootstrap authority / transport 分离）：
;;   identity   = 'flathub
;;   descriptor = 官方 flathub.flatpakrepo URL——我们明确信任官方
;;                descriptor 当前提供的 GPGKey（trust lifecycle 由
;;                upstream 持有：续期/轮换在下次 bootstrap /
;;                remote-replace 时自然获取，仓库不 vendor key、
;;                不 pin fingerprint、不维护过期日期）
;;   transport  = SJTU 镜像裸 OSTree URL（镜像内容 = 官方仓库同副本、
;;                同一份已签名 summary，GPG 验证不变）
;; 换源 = 改 repository-url（transport），然后
;; `blue flatpak remote-replace <name>`（显式）；换 trust
;; authority = 改 descriptor-url。drift 检查只针对 transport。
(define %flatpak-remotes
  (list (flatpak-remote
         (name 'flathub)
         (descriptor-url "https://dl.flathub.org/repo/flathub.flatpakrepo")
         (repository-url "https://mirror.sjtu.edu.cn/flathub")
         (comment "Flathub via SJTU mirror"))))

;; Catalog：已知 Flatpak 应用（纯聚合——定义在 applications/ 下）。
(define %flatpak-applications
  (list %flatpak-qq
        %flatpak-wechat
        %flatpak-aagl
        %flatpak-steam))

;; 应用 selection 缺省：全局用户软件 policy——每台设备的用户态
;; Flatpak 集合完全一致；硬件差异不通过 selection 表达，只经
;; (flatpak-applications-with-environments) 对 managed override
;; 追加 environment adapter（如 NVIDIA PRIME），见
;; docs/architecture/flatpak.md（driver overlays）。
(define %flatpak-selection
  '(qq wechat aagl steam))

;; Catalog：已知 extension（auxiliary ref；定义在 extensions/ 下）。
(define %flatpak-extensions
  (list %flatpak-extension-gamescope
        %flatpak-extension-proton-ge))

;; Extension selection 缺省：全局用户能力。gamescope / proton-ge 不是
;; 硬件驱动；真正的 NVIDIA GL/GL32 extension 由 Flatpak 依据 active
;; GL driver 自动匹配，不进入本 selection。
(define %flatpak-extension-selection '(gamescope proton-ge))

;; fail-fast（模块加载即校验；apps/registry.scm 同款）。
(validate-flatpak-catalog! %flatpak-remotes %flatpak-applications)
(validate-flatpak-selection! %flatpak-selection %flatpak-applications)
(validate-flatpak-extension-catalog! %flatpak-remotes %flatpak-extensions)
(validate-flatpak-extension-selection! %flatpak-extension-selection
                                       %flatpak-extensions)
