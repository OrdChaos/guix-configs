;;; System-owned OpenSSH server：机器级 SSH 策略与 host-key 持久化。
;;;
;;; 所有权边界（Guix System owns）：
;;;   sshd、SSH server policy、SSH host keys、authorized-keys 策略。
;;; 普通用户通过系统密码或公钥登录；root 通过一切认证
;;; 方式（password/pubkey/keyboard-interactive/...）完全禁止。
;;;
;;; 无状态 root 适配：当前根是 ephemeral root generation，/etc/ssh
;;; 里的 host keys 会随 generation 重建而更换，导致宿主每次
;;; REMOTE HOST IDENTIFICATION HAS CHANGED。host keys 持久化在
;;; /persist/system/ssh/（机器状态），首启自动生成（root 所有、
;;; private 0600、public 可读），之后跨 root generation 稳定不变。

(define-module (guixcfg system ssh)
               #:use-module (gnu services)            ; service、simple-service
               #:use-module (gnu services ssh)        ; openssh-service-type
               #:use-module (gnu packages ssh)        ; openssh
               #:use-module (guixcfg storage model)   ; persist-mount-point（/persist 语义路径 authority）
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure
               #:export (%ssh-host-key-dir
                         ssh-host-key-activation
                         ssh-host-key-service
                         secure-ssh-service))

;; SSH host key 持久化目录（机器状态，跨 root generation 不变）。
(define %ssh-host-key-dir
  (string-append (persist-mount-point "@persist-system") "/ssh"))

;;; ────────────────────────────────────────────────────────────
;;; 首启 host-key 生成（activation 阶段，sshd 启动前）。
;;; 只生成现代必需类型（ed25519）；owner root、private 0600、
;;; public 可读。已存在时不动（跨 generation 稳定）。

(define (ssh-host-key-activation)
  "activation gexp：确保 %SSH-HOST-KEY-DIR 存在且 ed25519 host key
已生成（缺失才生成）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (mkdir-p #$%ssh-host-key-dir)
                            (let ((key (string-append #$%ssh-host-key-dir
                                                      "/ssh_host_ed25519_key")))
                              (unless (file-exists? key)
                                (invoke (string-append #$(file-append openssh "/bin/ssh-keygen"))
                                        "-t" "ed25519" "-N" "" "-f" key)
                                (chmod key #o600)
                                (chmod (string-append key ".pub") #o644))
                              ;; 目录本身 root 可读写即可（权限 0755）。
                              (chmod #$%ssh-host-key-dir #o755)))))

;;; ────────────────────────────────────────────────────────────
;;; System-owned OpenSSH server policy（production VM）。

(define (secure-ssh-service)
  "System-owned OpenSSH server：
  - 普通用户 password 与 pubkey 登录均允许；
  - root 通过一切认证方式完全禁止（PermitRootLogin no + DenyUsers root）；
  - 空密码禁用；
  - host keys 只来自 /persist/system/ssh/（首启由 activation 生成）。
sshd 配置与 host-key 持久化由 System 拥有；Guix Home 不管理 sshd，
也不创建任何私钥。"
  (service openssh-service-type
           (openssh-configuration
            (port-number 22)
            ;; #f 生成 PermitRootLogin no（guix 的 permit-root-login 字段
            ;; 不支持 'no 符号——match 只认 #t/#f/without-password/
            ;; prohibit-password，实测 match-error）。
            (permit-root-login #f)
            (allow-empty-passwords? #f)
            (password-authentication? #t)
            (public-key-authentication? #t)
            ;; 我们自己管理 host keys（/persist/system/ssh），
            ;; 禁用默认 /etc/ssh/ssh_host_* 生成。
            (generate-host-keys? #f)
            (extra-content (string-append
                            "HostKey " %ssh-host-key-dir
                            "/ssh_host_ed25519_key\n"
                            "DenyUsers root\n")))))

;;; ────────────────────────────────────────────────────────────
;;; host-key activation 的服务组合（vm.scm 的 %vm-services 使用）。

(define (ssh-host-key-service)
  "把首启 host-key 生成挂到系统 activation（sshd 启动前执行）。"
  (simple-service 'ssh-host-keys activation-service-type
                  (ssh-host-key-activation)))
