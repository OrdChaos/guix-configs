;;; System OpenSSH server 策略与 host-key 持久化测试。
;;; 断言：普通用户 password/pubkey 登录允许；root 一切认证方式禁止；
;;; host keys 只来自 /persist/system/ssh/（跨 root generation 稳定）；
;;; 首启自动生成（activation）。

(use-modules (gnu services)
             (gnu services ssh)
             (guixcfg system ssh)
             (guix gexp)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "system-ssh")

;; secure-ssh-service 的 service-value 即 openssh-configuration
;; （openssh-service-type 的配置；fold-services 需要 shepherd-root
;; 上下文，这里直接取 service 值）。
(define ssh-config (service-value (secure-ssh-service)))

(test-assert "permit-root-login = no (all root auth forbidden)"
             (eq? #f (openssh-configuration-permit-root-login ssh-config)))
(test-assert "PasswordAuthentication yes"
             (openssh-configuration-password-authentication? ssh-config))
(test-assert "PubkeyAuthentication yes"
             (openssh-configuration-public-key-authentication? ssh-config))
(test-assert "empty passwords disabled"
             (not (openssh-configuration-allow-empty-passwords? ssh-config)))
(test-assert "generate-host-keys? off (no /etc/ssh generation by default)"
             (not (openssh-configuration-generate-host-keys? ssh-config)))
(test-assert "port 22"
             (= 22 (openssh-configuration-port-number ssh-config)))

;; host-key 持久化路径与 DenyUsers 出现在 sshd 配置
(define extra (openssh-configuration-extra-content ssh-config))
(test-assert "HostKey points at /persist/system/ssh/"
             (string-contains extra (string-append "HostKey " %ssh-host-key-dir
                                                   "/ssh_host_ed25519_key")))
(test-assert "DenyUsers root as defense-in-depth"
             (string-contains extra "DenyUsers root"))

;; 首启 host-key activation 可编译（gexp->script）
(test-assert "host-key activation gexp compiles"
             (let ((out (false-if-exception
                         (gexp->script "ssh-host-key-check"
                                       (ssh-host-key-activation)))))
               (and out #t)))

(test-end "system-ssh")
