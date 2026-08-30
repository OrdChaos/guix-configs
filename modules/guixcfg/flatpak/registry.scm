;;; Flatpak registry：Catalog（Known Applications）+ Selection
;;; （Desired Applications）。显式列表——目录存在 ≠ 启用；名字查重
;;; 与 selection ⊆ catalog 在模块加载时 fail-fast（apps/registry
;;; 同款）。
;;;
;;; Catalog / Selection 分离（docs/architecture/flatpak.md
;;; （catalog/selection））：
;;;   - %flatpak-applications（Catalog）：identity + resource
;;;     ownership；persistence rules 从这里派生（与 selection
;;;     无关——selection removal 不撕 bind，不产生 split-brain）；
;;;   - %flatpak-selection（Selection）：sync 应该 ensure 哪些
;;;     logical names；即使 VM/Laptop 当前相同也独立存在（desired
;;;     lifecycle ≠ persistence lifecycle 的结构要求）；
;;;   - host 层只知道 logical name，不知道 app-id/remote/branch/
;;;     路径（未来 per-host 差异时在 hosts/*.scm 定义各自列表）。

(define-module (guixcfg flatpak registry)
               #:use-module (guixcfg flatpak model)
               #:export (%flatpak-remotes
                         %flatpak-applications
                         %flatpak-selection))

;; Remote 定义。Flathub：location 是官方 bootstrap descriptor URL
;; （含 GPG trust material，flatpak 添加时抓取解析——联网，只发生在
;; 显式 sync）；repository-url 是建立后的 effective repo URL，用于
;; drift 检查（flatpak remotes --user --columns=name,url），两者
;; 语义独立不可互相比较。信任决策：跟随 Flathub 官方 descriptor，
;; GPG 签名验证由 flatpak 内置执行，项目不管理 key material、
;; 不建模 fingerprint。
(define %flatpak-remotes
  (list (flatpak-remote
         (name 'flathub)
         (location "https://dl.flathub.org/repo/flathub.flatpakrepo")
         (repository-url "https://dl.flathub.org/repo/")
         (comment "Flathub official repository"))))

;; Catalog：已知 Flatpak 应用（identity + resource ownership）。
;;
;; 采用 Flatpak 的标准：Guix/channel 生态不方便提供、维护成本明显
;; 过高、或天然更适合 Flatpak 的少数 GUI 应用（overview.md 软件
;; 分类）。
;;
;;   qq —— 腾讯 QQ Linux（Electron 二进制，Guix 无对应包，上游
;;   更新频繁，天然适合 Flatpak 分发）。app-id/branch 以 Flathub
;;   官方页面核实（flathub.org/apps/com.qq.QQ，branch=stable）。
;;   commit #f = branch tracking（默认策略；如需 pin 必须注释理由）。
;;   overrides #f = 仓库不拥有 override 文件（user/Flatseal owns）：
;;   先以上游 manifest 权限运行；实机验证发现真正需要的 delta 后，
;;   按 Flatseal 实验工作流（flatpak.md（overrides））回填声明。
(define %flatpak-applications
  (list (flatpak-application
         (name 'qq)
         (id "com.qq.QQ")
         (remote 'flathub)
         (branch "stable"))))

;; Selection：sync 应 ensure 的 logical names。VM/Laptop 当前相同，
;; 但 Selection 独立存在（desired lifecycle ≠ persistence lifecycle
;; 的结构要求——从 selection 删除 ≠ 卸 ref/撕 bind）。
(define %flatpak-selection
  '(qq))

;; fail-fast（模块加载即校验；apps/registry.scm 同款）。
(validate-flatpak-catalog! %flatpak-remotes %flatpak-applications)
(validate-flatpak-selection! %flatpak-selection %flatpak-applications)
