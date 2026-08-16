;;; Boot readiness capabilities（docs/system-home-boundaries.md J8 /
;;; Boot Readiness Contract）。
;;;
;;; 六个语义 capability（阶段语义，不是函数执行状态）：
;;;
;;;   persistent-state-ready      persist 子卷 + boot-critical 状态已挂载
;;;   account-state-ready         /etc/{passwd,group,shadow} 合成正确
;;;   interactive-secrets-ready   login-critical runtime secrets 已发布
;;;   home-ready                  当前 system generation 的 Home 投影完成
;;;   session-infra-ready         elogind/PAM 会话基础设施可用
;;;   interactive-session-ready   纯 join barrier（login gate 开启点）
;;;
;;; 一致性不由服务顺序保证，而由 dependency graph + transactional
;;; publication + login gate 三层保证。服务完成顺序可以不同，消费者
;;; 看不到半完成状态。

(define-module (guixcfg system readiness)
               #:use-module (gnu services)              ; simple-service
               #:use-module (gnu services shepherd)     ; shepherd-service、user-processes-service-type
               #:use-module (gnu system pam)           ; pam-extension、pam-entry、pam-service
               #:use-module (gnu services base)        ; mingetty-service-type
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure
               #:export (persistent-state-ready-service
                         home-ready-service
                         session-infra-ready-service
                         interactive-session-ready-service
                         user-processes-requirements-service
                         readiness-services
                         login-gate-activation
                         login-gate-pam-service
                         login-gate-services
                         %login-gate-path
                         %interactive-session-requirements))

;; interactive-session-ready 的四个 prerequisite（Section 19）。
(define %interactive-session-requirements
  '(account-state-ready
    interactive-secrets-ready
    home-ready
    session-infra-ready))

;;; ────────────────────────────────────────────────────────────
;;; persistent-state-ready：file-systems 的就绪 + 关键持久路径在位
;;; 的语义聚合（不复制 mount 逻辑——只确认 boot-critical persistent
;;; substrate 可用）。

(define (persistent-state-ready-service)
  "确认 boot-critical persistent filesystem 已挂载的 one-shot 服务
（/persist 及 accounts/keys 子路径；这些是后续 account projection
与 secret 解密的前提）。"
  (simple-service 'persistent-state-ready shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(persistent-state-ready))
                         (requirement '(file-systems))
                         (one-shot? #t)
                         (documentation
                          "Persistent boot-critical state is mounted and \
available (provides persistent-state-ready).")
                         (start
                          #~(lambda ()
                              ;; gexp 内只有 guile core + 显式列出的模块
                              ;; 可用——every 来自 srfi-1，必须显式引入。
                              (use-modules (srfi srfi-1))
                              (every file-exists?
                                     '("/persist/system"
                                       "/persist/data-home"
                                       "/var/guix"
                                       "/gnu/store"))))
                         (stop #~(const #f))))))

;;; ────────────────────────────────────────────────────────────
;;; home-ready / session-infra-ready：对上游服务的薄包装（上游
;;; provision 名固定，不能加 capability——本服务只做语义转发，
;;; 不做业务工作）。

(define (home-ready-service home-provision)
  "HOME-PROVISION（如 guix-home-user）成功完成后 provision
home-ready——表示当前 system generation 的 Home 已投影到 ephemeral
$HOME（不要求 user Shepherd 运行）。"
  (simple-service 'home-ready shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(home-ready))
                         (requirement (list home-provision))
                         (one-shot? #t)
                         (documentation
                          "Home projection for the current system \
generation is complete (provides home-ready).")
                         (start #~(const #t))
                         (stop #~(const #f))))))

(define (session-infra-ready-service)
  "elogind 完成启动后 provision session-infra-ready——系统已能正确
创建 user session（XDG_RUNTIME_DIR 创建能力、seat/session 基础
设施）。不含 PipeWire/portal 等 login 后服务。"
  (simple-service 'session-infra-ready shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(session-infra-ready))
                         (requirement '(elogind))
                         (one-shot? #t)
                         (documentation
                          "Session infrastructure (elogind/PAM substrate) \
is ready (provides session-infra-ready).")
                         (start #~(const #t))
                         (stop #~(const #f))))))

;;; ────────────────────────────────────────────────────────────
;;; interactive-session-ready：纯 join barrier（systemd target 角色，
;;; Shepherd 原生机制）。不做业务工作：不 cp/chmod/部署/激活/启动
;;; 别的服务/轮询——只表达"所有 prerequisite 已成功"。
;;; gate 的开启由本服务完成（它是 login gate 的唯一 owner 的打开端）。

(define (interactive-session-ready-service)
  "纯 barrier：account-state-ready、interactive-secrets-ready、
home-ready、session-infra-ready 全部成功后 provision
interactive-session-ready 并原子打开 login gate
（删除 /run/guixcfg/session-not-ready）。"
  (simple-service 'interactive-session-ready shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(interactive-session-ready))
                         (requirement %interactive-session-requirements)
                         (one-shot? #t)
                         (documentation
                          "All interactive prerequisites are ready; opens \
the login gate (provides interactive-session-ready).")
                         (start
                          #~(lambda ()
                              ;; gate 单一 owner：只有本服务创建/删除
                              ;; gate 文件。
                              (false-if-exception
                               (delete-file
                                "/run/guixcfg/session-not-ready"))
                              #t))
                         (stop #~(const #f))))))

;;; ────────────────────────────────────────────────────────────
;;; user-processes 聚合（Section 20）：account-state-ready 与
;;; interactive-secrets-ready 注入为 user-processes 的 prerequisite
;;; ——其后启动的服务（guix-home-user 等）自然在 system-state 阶段
;;; 完成后才开始。

(define (user-processes-requirements-service)
  "把 account-state-ready 与 interactive-secrets-ready 注入
user-processes 的 requirement。user-processes-service-type 由
essential-services 自动实例化（gnu system.scm）——本服务经
simple-service 扩展其 requirement 列表（同 urandom-seed 等上游
扩展的模式），值是 prerequisite provision 符号列表。"
  (simple-service 'user-processes-interactive-prerequisites
                  user-processes-service-type
                  '(account-state-ready interactive-secrets-ready)))

;;; ────────────────────────────────────────────────────────────
;;; 组合入口：host 挂一组 readiness 服务。

(define (readiness-services home-provision)
  "完整 readiness DAG（HOME-PROVISION 是 guix-home-service-type 生成
的服务 provision 名，如 guix-home-user）。"
  (list (persistent-state-ready-service)
        (user-processes-requirements-service)
        (home-ready-service home-provision)
        (session-infra-ready-service)
        (interactive-session-ready-service)))

;;; ────────────────────────────────────────────────────────────
;;; Interactive login gate（docs/system-home-boundaries.md J8）。

;; gate 文件：存在即拒绝普通 interactive 登录（pam_nologin 语义；
;; root 豁免是 pam_nologin 的标准行为——保留 console recovery 路径）。
;; 项目统一所有，不与系统其它 nologin owner 冲突。
(define %login-gate-path "/run/guixcfg/session-not-ready")

(define (login-gate-activation)
  "activation gexp：boot 早期关闭 gate（创建 gate 文件）。gate 由
interactive-session-ready 服务在全部 prerequisite 成功后原子打开。"
  (with-imported-modules (source-module-closure '((guix build utils)))
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p "/run/guixcfg")
        (chmod "/run/guixcfg" #o755)
        (call-with-output-file #$%login-gate-path
          (lambda (p)
            (display "The system is not ready for interactive logins yet.\n"
                     p))))))

(define (login-gate-pam-service)
  "PAM gate：对 login frontends（login、sshd——未来 greetd）的 account
段插入 pam_nologin.so file=<gate>。gate 文件存在时普通用户认证失败；
root 豁免是 pam_nologin 标准语义（console recovery 保留）。使用
pam-extension transformer（横切机制，同 elogind 的 pam_elogind
注入模式）。"
  (simple-service 'login-gate-pam pam-root-service-type
                  (list (pam-extension
                         (transformer
                          (lambda (pam)
                            (if (member (pam-service-name pam)
                                        '("login" "sshd"))
                                (pam-service
                                 (inherit pam)
                                 (account
                                  (cons (pam-entry
                                         (control "required")
                                         (module "pam_nologin.so")
                                         (arguments
                                          (list (string-append
                                                 "file="
                                                 %login-gate-path))))
                                        (pam-service-account pam))))
                                pam)))))))

(define (login-gate-services)
  "login gate 完整组合：activation（boot 早期关 gate）+ PAM 横切
（login/sshd account 段 pam_nologin）。"
  (list (simple-service 'login-gate activation-service-type
                        (login-gate-activation))
        (login-gate-pam-service)))
