;;; SmartDNS：与 Mihomo 解耦的系统 resolver（docs/architecture/dns.md）。
;;;
;;; 所有权：
;;;   - 应用查询入口为 127.0.0.1:53，由 SmartDNS 独占；
;;;   - fixed 模式只配置 AliDNS IP DoH，绝不引用 DHCP DNS；
;;;   - dhcp 模式只配置 NetworkManager dnsmasq (:15353)，绝不配置 DoH；
;;;   - 模式只由用户显式选择，不按 NetworkManager 连接自动推断；
;;;   - 模式选择持久化在 /var/lib/guixcfg-dns/mode，root applier 应用；
;;;   - 不提供自定义 CLI；插件直接写 mode 文件，root applier 是唯一执行者。
;;;
;;; 账号与 TUN：
;;;   SmartDNS 以 root 启动、绑定 127.0.0.1:53 后降权到 smartdns
;;;   （显式 UID 974）。Mihomo 的 tun.exclude-uid 同时排除 smartdns
;;;   与 nm-dnsmasq，使 DoH / DHCP 上游都不进入 TUN，切断 DNS 递归。
;;;
;;; 配置不变量：
;;;   - fixed 配置不得出现 127.0.0.1:15353；
;;;   - dhcp 配置不得出现 https://；
;;;   - 没有 fallback、没有 domain-rules、没有本地域名列表。

(define-module (guixcfg system dns smartdns)
  #:use-module (gnu services) ;service-type、service-extension
  #:use-module (gnu services shepherd) ;shepherd-service
  #:use-module (gnu system shadow) ;account-service-type
  #:use-module (gnu system accounts) ;user-account、user-group
  #:use-module (gnu packages admin) ;shepherd（herd 客户端）
  #:use-module (gnu packages dns) ;smartdns
  #:use-module (guix gexp) ;plain-file、program-file、file-append
  #:use-module (guix modules) ;source-module-closure
  #:use-module (guixcfg system machine-state-persistence)
  #:export (%smartdns-user %smartdns-uid %smartdns-gid
            %smartdns-state-directory %smartdns-run-directory
            %smartdns-mode-file %smartdns-applied-file
            %smartdns-status-file %smartdns-health-file %smartdns-runtime-config
            %smartdns-log-file
            %smartdns-fixed-config %smartdns-dhcp-config
            %smartdns-fixed-config-content %smartdns-dhcp-config-content
            %smartdns-mode-persistence-rule
            smartdns-mode-program smartdns-activation
            smartdns-service-type smartdns-service))

(define %smartdns-user
  "smartdns")

;; 显式、稳定的系统 ID（100..999 段）。985 已由 nm-dnsmasq 使用；984 与 sshd 冲突，
;; 974 在 sshd 984 冲突后重新选取；显式 UID 会被 ephemeral-root 的账号分配器跳过。
(define %smartdns-uid
  974)
(define %smartdns-gid
  974)

(define %smartdns-state-directory
  "/var/lib/guixcfg-dns")
(define %smartdns-run-directory
  "/run/guixcfg-dns")
(define %smartdns-mode-file
  (string-append %smartdns-state-directory "/mode"))
(define %smartdns-applied-file
  (string-append %smartdns-run-directory "/applied"))
(define %smartdns-status-file
  (string-append %smartdns-run-directory "/status"))
(define %smartdns-health-file
  (string-append %smartdns-run-directory "/smartdns-status"))
(define %smartdns-runtime-config
  (string-append %smartdns-run-directory "/smartdns.conf"))
(define %smartdns-log-file
  "/var/log/smartdns.log")

;; 模式选择是 machine-owned mutable state；与 mihomo cache 同一持久化
;; 模型：/persist/system/state/guixcfg-dns → bind → /var/lib/guixcfg-dns。
(define %smartdns-mode-persistence-rule
  (machine-state-persistence-rule (name 'guixcfg-dns-state)
                                  (backing "guixcfg-dns")
                                  (consumer %smartdns-state-directory)))

(define %smartdns-common-config
  (string-append
   "bind 127.0.0.1:53\n"
   "bind-tcp 127.0.0.1:53\n"
   "user " %smartdns-user "\n"
   "cache-size 4096\n"
   "speed-check-mode none\n"))

(define %smartdns-fixed-config-content
  (string-append
   %smartdns-common-config
   "server-https https://223.5.5.5/dns-query\n"
   "server-https https://223.6.6.6/dns-query\n"))

(define %smartdns-fixed-config
  (plain-file "smartdns-fixed.conf" %smartdns-fixed-config-content))

(define %smartdns-dhcp-config-content
  (string-append
   %smartdns-common-config
   "server 127.0.0.1:15353\n"))

(define %smartdns-dhcp-config
  (plain-file "smartdns-dhcp.conf" %smartdns-dhcp-config-content))
(define %smartdns-group
  (user-group (name %smartdns-user)
              (id %smartdns-gid)
              (system? #t)))

(define %smartdns-account
  (user-account (name %smartdns-user)
                (uid %smartdns-uid)
                (group %smartdns-user)
                (comment "SmartDNS resolver")
                (home-directory "/var/empty")
                (create-home-directory? #f)
                (system? #t)))

(define (smartdns-activation)
  "创建状态/运行目录和默认 fixed 配置链接。mode 文件由 root applier
在持久化 bind 就位后创建；activation 不写 mode 文件，避免被 bind
覆盖或制造双 owner。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                             (use-modules (guix build utils))
                             (mkdir-p #$%smartdns-state-directory)
                             (chmod #$%smartdns-state-directory #o755)
                             (mkdir-p #$%smartdns-run-directory)
                             (chmod #$%smartdns-run-directory #o755)
                             (unless (file-exists? #$%smartdns-runtime-config)
                               (symlink #$%smartdns-fixed-config
                                        #$%smartdns-runtime-config)))))

(define (smartdns-mode-program)
  "root mode applier：读取 /var/lib/guixcfg-dns/mode，验证 fixed/dhcp，
原子切换 SmartDNS 配置链接，然后通过 Shepherd 重启 SmartDNS。没有
自定义 CLI；panel 写 mode 文件，本程序是唯一执行者。"
  (program-file "guixcfg-dns-mode"
                (with-imported-modules (source-module-closure '((guix build utils)))
                  #~(begin
                      (use-modules (guix build utils)
                                   (ice-9 textual-ports)
                                   (ice-9 ftw)
                                   (srfi srfi-13))
                      (define mode-file #$%smartdns-mode-file)
                      (define applied-file #$%smartdns-applied-file)
                      (define status-file #$%smartdns-status-file)
                      (define health-file #$%smartdns-health-file)
                      (define runtime-config #$%smartdns-runtime-config)
                      (define herd #$(file-append shepherd "/bin/herd"))
                      (define configs
                        (list (cons "fixed" #$%smartdns-fixed-config)
                              (cons "dhcp" #$%smartdns-dhcp-config)))

                      (define (read-file path)
                        (catch 'system-error
                          (lambda ()
                            (call-with-input-file path get-string-all))
                          (lambda args #f)))

                      (define (write-file path content mode)
                        (call-with-output-file path
                          (lambda (port)
                            (display content port)))
                        (chmod path mode))

                      (define (normalize-mode raw)
                        (and raw
                             (let ((value (string-trim-both raw)))
                               (and (member value '("fixed" "dhcp"))
                                    value))))

                      (define (ensure-mode-file!)
                        (unless (file-exists? mode-file)
                          (write-file mode-file "fixed\n" #o666)))

                      (define (switch-config! mode)
                        (let* ((target (assoc-ref configs mode))
                               (tmp (string-append runtime-config ".new")))
                          (unless target
                            (error "unknown DNS mode" mode))
                          (when (file-exists? tmp)
                            (delete-file tmp))
                          (symlink target tmp)
                          (rename-file tmp runtime-config)))

                      (define (restart-smartdns!)
                        (or (zero? (system* herd "restart" "smartdns"))
                            ;; On first boot the applier may win the race
                            ;; against Shepherd's auto-start.
                            (zero? (system* herd "start" "smartdns"))))

                      (define (apply-mode! mode)
                        (catch 'system-error
                          (lambda ()
                            (switch-config! mode)
                            (if (restart-smartdns!)
                                (begin
                                  (write-file applied-file (string-append mode "\n") #o644)
                                  (write-file status-file "ok\n" #o644))
                                (write-file status-file
                                            "error: smartdns restart failed\n"
                                            #o644)))
                          (lambda (key . args)
                            (write-file status-file
                                        (string-append "error: " (object->string args) "\n")
                                        #o644)
                            #f)))

                      (define (smartdns-running?)
                        (catch #t
                          (lambda ()
                            (let loop ((pids (scandir "/proc"
                                                      (lambda (name)
                                                        (string->number name)))))
                              (if (null? pids)
                                  #f
                                  (let ((comm (read-file
                                               (string-append "/proc/"
                                                              (car pids)
                                                              "/comm"))))
                                    (if (and comm
                                             (string=? (string-trim-both comm)
                                                       "smartdns"))
                                        #t
                                        (loop (cdr pids)))))))
                          (lambda args #f)))

                      (define (write-health!)
                        (write-file health-file
                                    (if (smartdns-running?)
                                        "running\n"
                                        "stopped\n")
                                    #o644))

                      (define (run)
                        (ensure-mode-file!)
                        (let loop ((last #f))
                          (write-health!)
                          (let* ((raw (read-file mode-file))
                                 (mode (normalize-mode raw)))
                            (if (and mode (not (equal? mode last)))
                                (begin
                                  (apply-mode! mode)
                                  (loop mode))
                                (begin
                                  (sleep 1)
                                  (loop last))))))
                      (if (member "--check" (command-line))
                          (begin
                            (display "guixcfg-dns-mode: ok\n")
                            (exit 0))
                          (run))))))

(define %smartdns-shepherd-service
  (shepherd-service
   (provision '(smartdns))
   (requirement '(loopback user-processes))
   (documentation
    "Run SmartDNS on 127.0.0.1:53 with the mode-selected fixed/dhcp configuration.")
   (start #~(make-forkexec-constructor
             (list #$(file-append smartdns "/sbin/smartdns")
                   "-f"
                   "-p"
                   "-"
                   "-c"
                   #$%smartdns-runtime-config)
             #:log-file #$%smartdns-log-file))
   (stop #~(make-kill-destructor))))

(define %smartdns-mode-shepherd-service
  (shepherd-service
   (provision '(guixcfg-dns-mode))
   (requirement '(loopback user-processes))
   (documentation
    "Apply the persisted DNS mode (fixed DoH or DHCP DNS) to SmartDNS. No custom CLI; the mode file is the only writable input.")
   (start #~(make-forkexec-constructor
             (list #$(smartdns-mode-program))
             #:log-file "/var/log/guixcfg-dns-mode.log"))
   (stop #~(make-kill-destructor))))

(define smartdns-service-type
  (service-type
   (name 'smartdns)
   (extensions
    (list (service-extension shepherd-root-service-type
                             (lambda (config)
                               (list %smartdns-shepherd-service
                                     %smartdns-mode-shepherd-service)))
          (service-extension activation-service-type
                             (lambda (config)
                               (smartdns-activation)))
          (service-extension account-service-type
                             (lambda (config)
                               (list %smartdns-group %smartdns-account)))))
   (default-value #t)
   (description
    "Run SmartDNS as the application resolver with a manually selected
fixed-DoH or DHCP-DNS mode; Mihomo no longer owns DNS.")))

(define (smartdns-service)
  (service smartdns-service-type #t))
