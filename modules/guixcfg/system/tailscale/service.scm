;;; Tailscale system service + first-boot enrollment（docs/architecture/
;;; network.md 的虚拟组网方案）。
;;;
;;; 模型：profile 级 reusable preauth key（age 密文，ordinary domain）
;;; 只用于首次入网；入网后的 node identity 在 /var/lib/tailscale，
;;; 由 machine-state 持久化。设备重启/用户 `tailscale down` 后不会
;;; 被本服务强行拉起——只有 BackendState 仍处于未登录状态时才执行
;;; `tailscale up`。
;;;
;;; 与 mihomo 的边界（同一台机器两个 TUN）：
;;;   - mihomo 拥有默认路由；Tailscale 只拥有 100.64.0.0/10 和
;;;     Tailscale 自己的 underlay；
;;;   - underlay 的 WireGuard/STUN 端口由 mihomo 的 tun 排除项处理
;;;     （见 (guixcfg system mihomo template)）；
;;;   - 本模块不修改 mihomo 配置，也不依赖 mihomo 运行。
;;;
;;; 密钥纪律：preauth key 只以 age 密文进仓库；运行时由 generic
;;; secrets publisher 解密到 /run（root 0400），`tailscale up` 通过
;;; `--auth-key=file:...` 读取，密钥不进入 argv/environment/日志。

(define-module (guixcfg system tailscale service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (rosenthal packages networking) ;tailscale
  #:use-module ((rosenthal services networking)
                #:select (tailscale-configuration tailscale-service-type))
  #:use-module (guixcfg security secrets)
  #:use-module (guixcfg system machine-state-persistence)
  #:export (%tailscale-state-directory %tailscale-enrollment-secret
                                       %tailscale-secrets
                                       %tailscale-data-persistence-rule
                                       tailscale-enrollment-configuration
                                       tailscale-enrollment-configuration?
                                       tailscale-enrollment-login-server
                                       tailscale-enrollment-auth-key-file
                                       tailscale-enrollment-accept-dns?
                                       tailscale-enrollment-accept-routes?
                                       tailscale-enrollment-netfilter-mode
                                       tailscale-enrollment-timeout
                                       tailscale-up-arguments
                                       tailscale-enroll-program
                                       tailscale-enroll-shepherd-service
                                       tailscale-enroll-service-type
                                       tailscale-operator-program
                                       tailscale-operator-service-type
                                       tailscale-services))

(define %tailscale-state-directory
  "/var/lib/tailscale")

;; 每个 profile 一份 reusable preauth key；只用于首次入网。
;; source 是 age 密文（colocate），plaintext 仅由 generic publisher
;; 在 boot 时物化到 /run。
(define %tailscale-enrollment-secret
  (secret-decl (name 'tailscale-enrollment)
               (scope 'system)
               (domain 'ordinary)
               (source (local-file "secrets/enroll.age" "tailscale-enroll.age"))
               (target-name "tailscale-enroll")
               (owner-user "root")
               (mode 256)))

(define %tailscale-secrets
  (list %tailscale-enrollment-secret))

;; Tailscale 的 node identity（node key、prefs、DERP 状态）是机器
;; mutable state；canonical backing 在 /persist/system/state/tailscale。
(define %tailscale-data-persistence-rule
  (machine-state-persistence-rule (name 'tailscale-state)
                                  (backing "tailscale")
                                  (consumer %tailscale-state-directory)
                                  (owner 'root)
                                  (mode 448)))

(define-record-type* <tailscale-enrollment-configuration>
                     tailscale-enrollment-configuration
                     make-tailscale-enrollment-configuration
  tailscale-enrollment-configuration?
  (login-server tailscale-enrollment-login-server)
  (auth-key-file tailscale-enrollment-auth-key-file
                 (default (runtime-secret-target %tailscale-enrollment-secret
                                                 #f)))
  (accept-dns? tailscale-enrollment-accept-dns?
               (default #f))
  (accept-routes? tailscale-enrollment-accept-routes?
                  (default #f))
  (netfilter-mode tailscale-enrollment-netfilter-mode
                  (default 'off))
  (timeout tailscale-enrollment-timeout
           (default "30s")))

(define (flag-boolean value)
  (if value "true" "false"))

(define (tailscale-up-arguments config)
  "CONFIG 对应的 `tailscale up` 参数（不含可执行文件路径）。
`--auth-key=file:...` 保证密钥内容不进入 argv。"
  (let ((mode (tailscale-enrollment-netfilter-mode config)))
    (unless (memq mode
                  '(off on nodivert))
      (error "tailscale: unsupported netfilter-mode" mode))
    (append (list "up"
                  "--login-server"
                  (tailscale-enrollment-login-server config)
                  (string-append "--auth-key=file:"
                                 (tailscale-enrollment-auth-key-file config))
                  (string-append "--accept-dns="
                                 (flag-boolean (tailscale-enrollment-accept-dns?
                                                config)))
                  (string-append "--accept-routes="
                                 (flag-boolean (tailscale-enrollment-accept-routes?
                                                config)))
                  (string-append "--netfilter-mode="
                                 (symbol->string mode))
                  (string-append "--timeout="
                                 (tailscale-enrollment-timeout config))))))

(define* (tailscale-enroll-program #:key config
                                   (tailscale-command (file-append tailscale
                                                       "/bin/tailscale")))
  "生成首次入网 one-shot 程序：仅当 tailscaled 仍处于未登录状态时
执行 `tailscale up`；已登录（包括用户主动 down）则 no-op。"
  (unless config
    (error "tailscale-enroll-program: config is required"))
  (program-file "tailscale-enroll"
                #~(begin
                    (use-modules (ice-9 popen)
                                 (ice-9 rdelim))
                    (define tailscale
                      #$tailscale-command)
                    (define (status-json)
                      (catch #t
                             (lambda ()
                               (let* ((port (open-input-pipe (string-append
                                                              tailscale
                                                              " status --json")))
                                      (text (read-string port)))
                                 (close-pipe port) text))
                             (lambda args
                               "")))
                    (define (run-up)
                      (let ((status (system* tailscale
                                             #$@(tailscale-up-arguments config))))
                        (exit (if (zero? status) 0 1))))
                    ;; tailscaled 刚启动时 status 可能暂时不可用；有界重试，避免
                    ;; one-shot 与 daemon 启动竞态。已登录但 Stopped 不作为
                    ;; 未登录处理——尊重用户 `tailscale down`。
                    (let loop
                      ((attempt 0))
                      (let ((status (status-json)))
                        (cond
                          ((or (string-contains status
                                                "\"BackendState\":\"NeedsLogin\"")
                               (string-contains status "\"Self\":null"))
                           (run-up))
                          ((or (string-contains status
                                                "\"BackendState\":\"Running\"")
                               (string-contains status
                                                "\"BackendState\":\"Starting\""))
                           (exit 0))
                          ((and (string-contains status
                                                 "\"BackendState\":\"Stopped\"")
                                (not (string-contains status "\"Self\":null")))
                           (exit 0))
                          ((< attempt 10)
                           (sleep 1)
                           (loop (+ attempt 1)))
                          (else (exit 1))))))))

(define* (tailscale-enroll-shepherd-service #:key config)
  (unless config
    (error "tailscale-enroll-shepherd-service: config is required"))
  (shepherd-service (documentation
                     "First-boot Tailscale enrollment using the profile-scoped age secret; no-op after enrollment or when the user has taken Tailscale down.")
                    (provision '(tailscale-enroll))
                    (requirement '(tailscaled ordinary-secrets-ready
                                              networking))
                    (one-shot? #t)
                    (respawn? #f)
                    (start #~(make-forkexec-constructor (list #$(tailscale-enroll-program
                                                                 #:config
                                                                 config))
                              #:log-file "/var/log/tailscale-enroll.log"))
                    (stop #~(make-kill-destructor))))

(define tailscale-enroll-service-type
  (service-type (name 'tailscale-enroll)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   (lambda (config)
                                     (list (tailscale-enroll-shepherd-service
                                            #:config config))))))
                (description
                 "First-boot Tailscale enrollment using a profile-scoped age secret.")))

(define* (tailscale-operator-program #:key operator
                                     (tailscale-command (file-append tailscale
                                                         "/bin/tailscale")))
  "生成 `tailscale set --operator=<user>` 程序，让日常 up/down 不需要
root。tailscaled 刚启动时 socket 可能尚不可用，因此有界重试。"
  (unless (and (string? operator)
               (> (string-length operator) 0))
    (error "tailscale-operator-program: operator is required" operator))
  (program-file "tailscale-operator"
                #~(begin
                    (define tailscale
                      #$tailscale-command)
                    (let loop
                      ((attempt 0))
                      (let ((status (system* tailscale "set" "--operator"
                                             #$operator)))
                        (if (zero? status)
                            (exit 0)
                            (if (< attempt 10)
                                (begin
                                  (sleep 1)
                                  (loop (+ attempt 1)))
                                (exit 1))))))))

(define tailscale-operator-service-type
  (service-type (name 'tailscale-operator)
                (extensions (list (service-extension
                                   shepherd-root-service-type
                                   (lambda (operator)
                                     (list (shepherd-service (documentation
                                                              "Allow the primary user to run tailscale up/down without root.")
                                                             (provision '(tailscale-operator))
                                                             (requirement '(tailscaled))
                                                             (one-shot? #t)
                                                             (respawn? #f)
                                                             (start #~(make-forkexec-constructor
                                                                       (list #$
                                                                             (tailscale-operator-program
                                                                              #:operator
                                                                              operator))
                                                                       #:log-file
                                                                       "/var/log/tailscale-operator.log"))
                                                             (stop #~(make-kill-destructor))))))))
                (description
                 "Set the Tailscale CLI operator for the primary user.")))

(define* (tailscale-services #:key login-server
                             operator
                             (auth-key-file (runtime-secret-target
                                             %tailscale-enrollment-secret #f))
                             (accept-dns? #f)
                             (accept-routes? #f)
                             (netfilter-mode 'off)
                             (timeout "30s"))
  "Tailscaled + first-boot enrollment services。LOGIN-SERVER 是
Headscale/Tailscale 控制面 URL（含端口）；其余参数是客户端偏好。"
  (unless (and (string? login-server)
               (> (string-length login-server) 0))
    (error "tailscale-services: login-server is required" login-server))
  (let ((config (tailscale-enrollment-configuration (login-server login-server)
                                                    (auth-key-file
                                                     auth-key-file)
                                                    (accept-dns? accept-dns?)
                                                    (accept-routes?
                                                     accept-routes?)
                                                    (netfilter-mode
                                                     netfilter-mode)
                                                    (timeout timeout))))
    (list (service tailscale-service-type
                   (tailscale-configuration (state-directory
                                             %tailscale-state-directory)
                                            (socket
                                             "/run/tailscale/tailscaled.sock")
                                            (log-file
                                             "/var/log/tailscaled.log")
                                            (extra-options '("--port=41641"))))
          (service tailscale-enroll-service-type config)
          (if operator
              (service tailscale-operator-service-type operator)
              (begin
                (error "tailscale-services: operator is required" operator))))))
