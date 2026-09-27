;;; SmartDNS system service（Phase 2 v1，docs/architecture/dns.md）。
;;;
;;; 自建 thin service（同 mihomo 模式），复用 Guix 官方 smartdns
;;; package（pin 47，gnu/packages/dns.scm）。不复用 Rosenthal
;;; smartdns-service-type 的原因：其 shepherd 无 #:log-file（-f 的
;;; 日志被丢弃，排障不可用）、provision 含 'dns（本仓库无消费者），
;;; 且 config 无扩展面——本模块只多 ~40 行、语义全部本仓库所有。
;;;
;;; v1 边界（不引入分流/过滤/测速/ECS/DoH bootstrap）：
;;;   - 只监听 loopback（127.0.0.1:53，UDP+TCP；刻意不绑 [::1]——
;;;     resolver 是 v4-literal，绑 [::1] 会在 IPv6 禁用时启动失败）——
;;;     smartdns 默认 bind [::]:53 监听所有接口，必须显式收紧；
;;;   - 固定 IP literal upstream（无 hostname bootstrap；mihomo 侧
;;;     加对应 DIRECT 规则保证不绕经节点——见 mihomo-template.yaml）；
;;;   - cache 仅内存（cache-persist no；丢失代价=首查稍慢）；
;;;   - DHCP DNS 只作 fallback：NetworkManager 的 link/DHCP/DNS dispatcher
;;;     从 openresolv metadata 生成 runtime include；固定上游仍是默认。
;;;
;;; failure semantics（VM 实测 smartdns 47）：
;;;   - 固定 upstream 不可达：若 DHCP fallback 存在则降级查询它，否则
;;;     daemon 正常运行、查询 SERVFAIL（~2s 超时）；网络恢复后自动恢复；
;;;   - crash：/etc/resolv.conf 仍指 127.0.0.1 → DNS unavailable =
;;;     fail-closed（不绕过本地 resolver）；respawn 默认开；
;;;   - SIGHUP = monitor 重启 child 重读 config（官方语义）。

(define-module (guixcfg system dns smartdns)
                #:use-module (gnu services)          ; service、service-type、service-extension
                #:use-module (gnu services shepherd) ; shepherd-service、shepherd-signal-action
                #:use-module (gnu packages bash)     ; bash-minimal（NM dispatcher wrapper）
                #:use-module (gnu packages dns)      ; smartdns
                #:use-module (gnu packages admin)    ; shepherd（herd）
                #:use-module (guix gexp)
                #:use-module (guix modules)          ; source-module-closure
                #:use-module (guixcfg system dns ownership) ; %dhcp-dns-metadata-path
                #:export (%smartdns-config-file
                          %smartdns-log-file
                          %smartdns-runtime-directory
                          %smartdns-dhcp-fallback-file
                          %smartdns-dhcp-fallback-program
                          %smartdns-dhcp-dispatcher
                          %smartdns-runtime-setup
                          smartdns-dhcp-setup-shepherd-service
                          smartdns-shepherd-service
                          smartdns-service-type
                          smartdns-service))

(define %smartdns-log-file "/var/log/smartdns.log")
(define %smartdns-runtime-directory "/run/smartdns")
(define %smartdns-dhcp-fallback-file
  (string-append %smartdns-runtime-directory "/dhcp-upstreams.conf"))
(define %smartdns-dhcp-dispatcher-path
  "/etc/NetworkManager/dispatcher.d/50-smartdns-dhcp-fallback")

;; v1 最小配置（公开、无 secret）。上游为固定 IP literal；不启用
;; cache-persist（无持久化需求）；不做测速/分流。
(define %smartdns-config-file
  ;; colocate 独立文件（dns/smartdns.conf；注释见该文件头）。
  (local-file "smartdns.conf" "smartdns.conf"))

(define %smartdns-dhcp-fallback-program
  ;; The dispatcher runs this as root after NetworkManager reports a DNS
  ;; change.  Only strict IPv4 nameserver entries become SmartDNS syntax:
  ;; DHCP input never gets to inject arbitrary configuration directives.
  (program-file
   "smartdns-dhcp-fallback"
   (with-imported-modules
        (source-module-closure
        '((guix build utils)
          (ice-9 rdelim)
          (srfi srfi-1)
          (srfi srfi-13)))
     #~(begin
         (use-modules (guix build utils)
                      (ice-9 rdelim)
                      (srfi srfi-1)
                      (srfi srfi-13))

         (define (valid-octet? text)
           (and (positive? (string-length text))
                (every char-numeric? (string->list text))
                (let ((number (string->number text)))
                  (and number (<= 0 number 255)))))

         (define (valid-ipv4? text)
           (let ((parts (string-split text #\.)))
             (and (= (length parts) 4)
                  (every valid-octet? parts))))

         (define (dhcp-nameservers path)
           (if (file-exists? path)
               (call-with-input-file
                path
                (lambda (port)
                  (let loop ((servers '()))
                    (let ((line (read-line port)))
                      (if (eof-object? line)
                          (reverse servers)
                          (let ((words (string-tokenize line)))
                            (if (and (= (length words) 2)
                                     (string=? (car words) "nameserver")
                                     (valid-ipv4? (cadr words))
                                     (not (member (cadr words) servers)))
                                (loop (cons (cadr words) servers))
                                (loop servers))))))))
               '()))

         (define (atomic-write-fallback! target servers)
           ;; /run is ephemeral, so visibility atomicity is the only required
           ;; property: SmartDNS sees either the old complete file or the new
           ;; complete file, never a partially written config.
           (let ((new (string-append target ".new")))
             (call-with-output-file
              new
              (lambda (port)
                (for-each (lambda (server)
                            (format port "server ~a -fallback~%" server))
                          servers)))
             (chmod new #o644)
             (rename-file new target)))

         (let ((arguments (cdr (command-line))))
           (unless (or (null? arguments) (= (length arguments) 2))
             (error "usage: smartdns-dhcp-fallback [SOURCE TARGET]"))
           (let ((source (if (null? arguments)
                             #$%dhcp-dns-metadata-path
                             (car arguments)))
                 (target (if (null? arguments)
                             #$%smartdns-dhcp-fallback-file
                             (cadr arguments))))
             (mkdir-p (dirname target))
             (atomic-write-fallback! target (dhcp-nameservers source))))))))

(define %smartdns-dhcp-dispatcher
  (program-file
   "smartdns-dhcp-dispatcher"
   #~(begin
       ;; NetworkManager invokes dispatcher scripts with IFACE ACTION.  React
       ;; to every event that can change the active DNS (activation, DHCP
       ;; lease, connectivity, DNS).  Relying on the dedicated dns-change
       ;; event alone was not robust: it can fire before this wrapper is
       ;; installed at boot or before openresolv writes the metadata, leaving
       ;; /run/smartdns/dhcp-upstreams.conf empty (observed 2026-09-28).
       (when (and (>= (length (command-line)) 3)
                  (member (caddr (command-line))
                          '("up" "dhcp4-change" "dhcp6-change"
                            "connectivity-change" "dns-change")))
         (unless (zero? (system* #$%smartdns-dhcp-fallback-program))
           (error "failed to materialize DHCP DNS fallback"))
         ;; During NetworkManager's first start SmartDNS may not be running
         ;; yet; its later start reads the already materialized include.  A
         ;; running service must reload successfully so stale DNS never lingers.
         (when (zero? (system* #$(file-append shepherd "/bin/herd")
                               "status" "smartdns"))
           (unless (zero? (system* #$(file-append shepherd "/bin/herd")
                                   "reload" "smartdns"))
             (error "failed to reload smartdns")))))))

(define %smartdns-runtime-setup
  ;; Install the NetworkManager dispatcher wrapper and materialize the DHCP
  ;; fallback include.  NetworkManager 1.54 rejects dispatcher symlinks, and
  ;; Guix's etc-service can only project store objects as symlinks, so a
  ;; root-owned regular wrapper must be written directly.
  ;;
  ;; This runs from the SmartDNS shepherd start, which executes on the real
  ;; root after file-systems; boot-time activation runs too early in the
  ;; custom ephemeral-root flow for /etc writes to survive (2026-09-28:
  ;; wrapper absent after reboot but created by the same code run manually
  ;; post-boot).  Activation still invokes it to cover live reconfigure.
  (program-file
   "smartdns-runtime-setup"
   (with-imported-modules
    (source-module-closure '((guix build utils)))
    #~(begin
        (use-modules (guix build utils))
        (let* ((target #$%smartdns-dhcp-dispatcher-path)
               (new (string-append target ".new")))
          (mkdir-p (dirname target))
          (call-with-output-file
           new
           (lambda (port)
             (format port "#!~a~%exec ~a \"$@\"~%"
                     #$(file-append bash-minimal "/bin/sh")
                     #$%smartdns-dhcp-dispatcher)))
          (chmod new #o555)
          (rename-file new target))
        (mkdir-p #$%smartdns-runtime-directory)
        (chmod #$%smartdns-runtime-directory #o755)
        (unless (zero? (system* #$%smartdns-dhcp-fallback-program))
          (error "failed to materialize DHCP DNS fallback"))))))

(define (smartdns-dhcp-setup-shepherd-service)
  "one-shot: install the NetworkManager dispatcher wrapper and materialize
the DHCP fallback include on the real root, before smartdns starts.

Must run as a service start, not from the service definition or from boot
activation: calling the setup program while shepherd loads the service file
(or from the boot PID1 activation via a nested `system*') deadlocks on child
reaping (2026-09-28: the deployed generation hung before shepherd started).
The start thunk below runs on the real root after file-systems, matching the
proven mihomo-config-ready / gvfs-mount-metadata pattern."
  (list (shepherd-service
         (provision '(smartdns-dhcp-setup))
         (requirement '(loopback))
         (one-shot? #t)
         (respawn? #f)
         (documentation
          "Write the regular NetworkManager dispatcher wrapper and
materialize /run/smartdns/dhcp-upstreams.conf.")
         (start #~(lambda ()
                    (unless (zero? (system* #$%smartdns-runtime-setup))
                      (error "failed to set up SmartDNS runtime"))))
         (stop #~(const #f)))))

(define (smartdns-shepherd-service)
  (list (shepherd-service
         (provision '(smartdns))
         (requirement '(loopback networking smartdns-dhcp-setup))
          (documentation
           "Run SmartDNS as the system resolver (loopback only; fixed \
upstreams; DHCP DNS is a runtime fallback after fixed upstream failure).")
          (actions
           (list (shepherd-signal-action
                  'reload SIGHUP
                  #:documentation
                  "Reload SmartDNS after NetworkManager changes DHCP DNS.")))
          (start #~(make-forkexec-constructor
                   (list #$(file-append smartdns "/sbin/smartdns")
                         "-f" "-c" #$%smartdns-config-file)
                   #:log-file #$%smartdns-log-file))
         (stop #~(make-kill-destructor)))))

(define smartdns-service-type
  (service-type
   (name 'smartdns)
     (extensions
      (list (service-extension shepherd-root-service-type
                               (lambda (config)
                                 (append (smartdns-dhcp-setup-shepherd-service)
                                         (smartdns-shepherd-service))))))
   (default-value #t)
    (description
    "Run SmartDNS as the sole system resolver: loopback-only listener \
with fixed explicit upstreams and DHCP fallback.")))

(define (smartdns-service)
  (service smartdns-service-type #t))
