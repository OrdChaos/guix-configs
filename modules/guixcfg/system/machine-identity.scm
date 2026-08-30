;;; Machine identity（/etc/machine-id）持久化接线：
;;; canonical 位于 /persist/system/machine-id（machine-owned identity，
;;; 与 SSH host keys / age identity 同层；docs/architecture/persistence.md
;;; （Machine-owned mutable system state））。
;;;
;;; 无状态 root 下，/etc/machine-id 随每次 ephemeral root 重建丢失。
;;; pinned Guix 的 D-Bus activation（gnu/services/dbus.scm 的
;;; dbus-activation）对缺失的 /etc/machine-id 执行
;;; `dbus-uuidgen --ensure=/etc/machine-id`——每次 reboot 生成新
;;; machine-id，machine-bound 的应用登录态随之失效（实测：Flatpak QQ
;;; reboot 后掉登录、账号记录丢失）。
;;;
;;; 本模块在 D-Bus activation 之前把 machine identity 从持久层投影到
;;; /etc/machine-id。状态机（生成/防覆盖/fail-closed/自愈）在
;;; (guixcfg utils machine-id)——纯机制、极小模块闭包；本模块只负责
;;; 路径事实（/persist/system/machine-id）与 activation 接线。
;;;
;;; 时序（本模块最重要的不变量）：必须先于 D-Bus activation 的
;;; dbus-uuidgen --ensure。Guix activation 脚本顺序 = fold-services
;;; 对 activation-service-type 的值顺序（essential 反序在前，user
;;; services 反序在后）；D-Bus service 由 instantiate-missing-services
;;; 插到 services 列表头部 → 其 activation gexp 在 user 段末尾执行。
;;; 因此 host 组装把本服务放在 services 列表末尾（紧随
;;; account-databases 投影），它在 user activation 段最先执行，
;;; 严格先于 dbus-uuidgen。tests/test-machine-identity.scm 断言该
;;; 顺序（防止未来有人把服务移到列表中部破坏时序）。
;;;
;;; closure 纪律：activation 脚本的 module-import 会合并本 gexp 的
;;; with-imported-modules 闭包；因此 gexp 只导入 (guixcfg utils
;;; machine-id)（闭包 = atomic-file + guix build utils，无 gnu
;;; packages 依赖）。dbus-uuidgen 以 (file-append dbus ...) 注入为
;;; store 路径（构建期求值），不产生模块依赖。
;;;
;;; /var/lib/dbus/machine-id 结论（dbus 1.16.2 源码审计）：
;;; DBUS_MACHINE_UUID_FILE = /var/lib/dbus/machine-id（localstatedir
;;; =/var），_dbus_read_local_machine_uuid 先读它、再回退 /etc/
;;; machine-id；但 dbus-daemon 以 create_if_not_found=#f 调用
;;; （bus/dispatch.c:3343、dbus-internals.c:996），Guix activation 又
;;; 只 ensure /etc/machine-id——本系统 /var/lib/dbus/machine-id 永远
;;; 不存在，/etc/machine-id 就是实际生效的来源。只持久化 /etc/
;;; machine-id 一个投影点：不额外创建 /var/lib/dbus/machine-id（那会
;;; 制造第二份 dbus 优先读取的副本，未来有漂移风险；/etc 存在且合法
;;; 时回退路径稳定生效）。

(define-module (guixcfg system machine-identity)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu packages glib)       ; dbus（dbus-uuidgen）
               #:use-module (guix gexp)               ; gexp、file-append
               #:use-module (guix modules)            ; source-module-closure
               #:use-module (guixcfg storage model)   ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guixcfg utils module-closure) ; guixcfg-module-select?
               #:export (%machine-id-path
                         %etc-machine-id-path
                         machine-identity-activation
                         machine-identity-service))

;; canonical machine-id：/persist/system 顶层的机器身份文件（与
;; boot-states.scm / facts/host.scm 同级；本模块拥有该路径）。
(define %machine-id-path
  (string-append (persist-mount-point "@persist-system") "/machine-id"))

;; /etc/machine-id 投影目标（FHS 固定位置，consumer 读取点）。
(define %etc-machine-id-path "/etc/machine-id")

;;; ────────────────────────────────────────────────────────────
;;; activation 接线：在 D-Bus activation（dbus-uuidgen --ensure）
;;; 之前把 machine identity 就位。host 组装必须把本服务放在 services
;;; 列表末尾（见文件头时序）。

(define (machine-identity-activation)
  "activation gexp：ensure canonical（首启生成一次）+ 投影 /etc/
machine-id。幂等：重复 activation / reconfigure / 每次 boot 结果
不变。"
  (with-imported-modules (source-module-closure '((guixcfg utils machine-id))
                                               #:select? guixcfg-module-select?)
    #~(begin
       (use-modules (guixcfg utils machine-id))
       (let ((canonical #$%machine-id-path))
         (ensure-machine-id!
          canonical
          (lambda ()
            (generate-machine-id
             (string-append #$(file-append dbus "/bin/dbus-uuidgen")))))
         (project-machine-id! canonical #$%etc-machine-id-path)))))

(define (machine-identity-service)
  "把 machine-id 初始化/恢复挂到系统 activation。必须排在 D-Bus
activation 之前（文件头时序）；host 组装时置于 services 列表末尾。"
  (simple-service 'machine-identity activation-service-type
                  (machine-identity-activation)))
