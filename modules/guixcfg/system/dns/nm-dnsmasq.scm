;;; NetworkManager-managed dnsmasq resolver（docs/architecture/dns.md）。
;;;
;;; NetworkManager 的 `dns=dnsmasq` backend 自己 exec 构建期烘焙的
;;; dnsmasq（store 路径编译进 NM binary），监听 127.0.0.1:53 并读取
;;; `--conf-dir=/etc/NetworkManager/dnsmasq.d`。本模块拥有该层唯一的
;;; project-specific 语义：dnsmasq 以一个**稳定 UID** 的专用系统账号
;;; 运行，使 mihomo TUN 可以用 `exclude-uid` 把 dnsmasq 的上游 DHCP
;;; DNS 查询排除出 TUN（切断 DNS → TUN → mihomo → DNS 递归）。
;;;
;;; 单一事实来源：
;;;   - 账号名 / UID / GID：本模块常量；
;;;   - 账号：经 account-service-type 贡献（不是 `users` 字段），与
;;;     mihomo 的 clash group 同模式；
;;;   - dnsmasq 配置：/etc/NetworkManager/dnsmasq.d/00-nm-dnsmasq-user.conf
;;;     （`user=<name>`），由 host 的 network-manager-configuration
;;;     `dnsmasq-configuration-files` 字段声明式物化；
;;;   - mihomo 的 `tun.exclude-uid` 引用同一 UID（见
;;;     (guixcfg system mihomo config) 的占位符替换）。
;;;
;;; UID 必须显式固定：ephemeral-root 每 boot 重建 /etc/passwd，
;;; 动态系统账号会漂移；显式 UID 同时被 (gnu build accounts) 的
;;; 分配器跳过，不会与其他系统账号冲突。

(define-module (guixcfg system dns nm-dnsmasq)
  #:use-module (gnu services) ;simple-service
  #:use-module (gnu system shadow) ;account-service-type
  #:use-module (gnu system accounts) ;user-account、user-group
  #:use-module (guix gexp) ;plain-file
  #:export (%nm-dnsmasq-user %nm-dnsmasq-uid
                             %nm-dnsmasq-gid
                             %nm-dnsmasq-account
                             %nm-dnsmasq-group
                             %nm-dnsmasq-conf-file
                             %nm-dnsmasq-conf-name
                             %nm-dnsmasq-conf-content
                             nm-dnsmasq-dnsmasq-configuration-files
                             nm-dnsmasq-account-service))

(define %nm-dnsmasq-user
  "nm-dnsmasq")

;; 显式、稳定的系统 ID（100..999 段）。取 985：当前系统账号分配从
;; 999 递减（greeter 999、polkitd 998、guixbuilder 997..988、sshd
;; 987、messagebus 986），985 空闲；显式 UID 会被分配器跳过。
(define %nm-dnsmasq-uid
  985)
(define %nm-dnsmasq-gid
  985)

(define %nm-dnsmasq-group
  (user-group
    (name %nm-dnsmasq-user)
    (id %nm-dnsmasq-gid)
    (system? #t)))

(define %nm-dnsmasq-account
  (user-account
    (name %nm-dnsmasq-user)
    (uid %nm-dnsmasq-uid)
    (group %nm-dnsmasq-user)
    (comment "NetworkManager dnsmasq resolver")
    (home-directory "/var/empty")
    (create-home-directory? #f)
    (system? #t)))

;; dnsmasq 在 conf-dir 内会读取此文件并把工作进程降到该用户（NM 不传
;; --user，因此这里生效）。NM 以 root 启动 dnsmasq，绑定 127.0.0.1:53
;; 后再 drop 到 nm-dnsmasq。
(define %nm-dnsmasq-conf-name
  "00-nm-dnsmasq-user.conf")

(define %nm-dnsmasq-conf-content
  (string-append "user=" %nm-dnsmasq-user "\n"))

(define %nm-dnsmasq-conf-file
  (plain-file %nm-dnsmasq-conf-name %nm-dnsmasq-conf-content))

(define (nm-dnsmasq-dnsmasq-configuration-files)
  "network-manager-configuration 的 `dnsmasq-configuration-files` 字段值。
host 的 NM 服务与 `(dns \"dnsmasq\")` 一起使用。"
  `((,%nm-dnsmasq-conf-name ,%nm-dnsmasq-conf-file)))

(define (nm-dnsmasq-account-service)
  "把专用 dnsmasq 账号/组贡献进 account-service-type（与 mihomo 的
clash group 同模式；不是 `users` 字段）。"
  (simple-service 'nm-dnsmasq-account account-service-type
                  (list %nm-dnsmasq-group %nm-dnsmasq-account)))
