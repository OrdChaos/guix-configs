;;; Boot readiness capability DAG 测试（docs/system-home-boundaries.md
;;; J8 / Boot Readiness Contract）：六个 *-ready 的 provision/
;;; requirement 结构与 join barrier 语义。

(use-modules (gnu services)
             (gnu services shepherd)
             (gnu system pam)           ; pam-service 访问器
             (guixcfg system readiness)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "readiness")

(define (shepherd-of svc)
  (car (service-value svc)))

;; persistent-state-ready：file-systems 后，检查 persist 关键路径
(let ((s (shepherd-of (persistent-state-ready-service))))
  (test-assert "persistent-state-ready provision"
    (member 'persistent-state-ready (shepherd-service-provision s)))
  (test-assert "persistent-state-ready after file-systems"
    (member 'file-systems (shepherd-service-requirement s)))
  (test-assert "persistent-state-ready one-shot"
    (shepherd-service-one-shot? s)))

;; home-ready：薄包装（上游 provision 固定）
(let ((s (shepherd-of (home-ready-service 'guix-home-user))))
  (test-assert "home-ready provision"
    (member 'home-ready (shepherd-service-provision s)))
  (test-assert "home-ready after home service"
    (member 'guix-home-user (shepherd-service-requirement s))))

;; session-infra-ready：elogind 后
(let ((s (shepherd-of (session-infra-ready-service))))
  (test-assert "session-infra-ready provision"
    (member 'session-infra-ready (shepherd-service-provision s)))
  (test-assert "session-infra-ready after elogind"
    (member 'elogind (shepherd-service-requirement s))))

;; interactive-session-ready：纯 barrier——四个 prerequisite +
;; one-shot + 不依赖业务细节
(let ((s (shepherd-of (interactive-session-ready-service))))
  (test-equal "interactive barrier requires exactly the four phases"
    %interactive-session-requirements
    (shepherd-service-requirement s))
  (test-assert "interactive barrier provision"
    (member 'interactive-session-ready (shepherd-service-provision s)))
  (test-assert "interactive barrier one-shot"
    (shepherd-service-one-shot? s)))

;; 组合：readiness-services 四个服务齐全（persistent-state、home、
;; session-infra、interactive-session barrier）
(test-equal "readiness-services composition"
  4 (length (readiness-services 'guix-home-user)))

;; ── login gate ────────────────────────────────────────────────
;; gate 路径项目统一所有；activation 关闭 + PAM 横切仅 login/sshd。
(test-equal "gate path is project-owned"
  "/run/guixcfg/session-not-ready" %login-gate-path)

(define gate-pam-svc (login-gate-pam-service))
;; simple-service 的 value 即 extension compute 的结果（pam-extension 列表）
(define gate-transformer
  (pam-extension-transformer (car (service-value gate-pam-svc))))

(define (pam-has-nologin? pam)
  (any (lambda (e)
         (string=? (pam-entry-module e) "pam_nologin.so"))
       (pam-service-account pam)))

(let ((sshd-pam (gate-transformer (pam-service (name "sshd"))))
      (login-pam (gate-transformer (pam-service (name "login"))))
      (sudo-pam (gate-transformer (pam-service (name "sudo")))))
  (test-assert "gate applies to sshd" (pam-has-nologin? sshd-pam))
  (test-assert "gate applies to login" (pam-has-nologin? login-pam))
  (test-assert "gate does NOT apply to sudo" (not (pam-has-nologin? sudo-pam)))
  (test-assert "gate entry uses project-owned file"
    (any (lambda (e)
           (and (string=? (pam-entry-module e) "pam_nologin.so")
                (member (string-append "file=" %login-gate-path)
                        (pam-entry-arguments e))))
         (pam-service-account sshd-pam))))

(test-end "readiness")
