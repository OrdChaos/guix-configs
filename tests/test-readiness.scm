;;; Boot readiness capability DAG 测试（docs/system-home-boundaries.md
;;; J8 / Boot Readiness Contract）：六个 *-ready 的 provision/
;;; requirement 结构与 join barrier 语义。

(use-modules (gnu services)
             (gnu services shepherd)
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

;; user-processes 注入（simple-service 扩展，值是 provision 符号列表）
(let ((s (user-processes-requirements-service)))
  (test-assert "user-processes gets account + secrets prerequisites"
    (and (member 'account-state-ready (service-value s))
         (member 'interactive-secrets-ready (service-value s))))
  (test-assert "extends user-processes-service-type"
    ;; simple-service 创建的新 type 的 extension target 是
    ;; user-processes-service-type（不是 type 本身）。
    (any (lambda (ext)
           (eq? (service-extension-target ext)
                user-processes-service-type))
         (service-type-extensions (service-kind s)))))

;; 组合：readiness-services 五个服务齐全
(test-equal "readiness-services composition"
  5 (length (readiness-services 'guix-home-user)))

(test-end "readiness")
