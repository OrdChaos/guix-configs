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

;; 从 secure-ssh-service 提取生效的 openssh-configuration（fold-services）
(define ssh-config
  (service-value
   (fold-services (list (secure-ssh-service))
                  #:target-type openssh-service-type)))

(test-eq "permit-root-login = no（root 一切认证方式禁止）"
         'no (openssh-configuration-permit-root-login ssh-config))
(test-assert "PasswordAuthentication yes"
  (openssh-configuration-password-authentication? ssh-config))
(test-assert "PubkeyAuthentication yes"
  (openssh-configuration-public-key-authentication? ssh-config))
(test-assert "empty passwords disabled"
  (not (openssh-configuration-allow-empty-passwords? ssh-config)))
(test-assert "generate-host-keys? off（默认 /etc/ssh 生成禁用）"
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
