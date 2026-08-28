;;; Mihomo system transparent proxy（Phase 1，docs/architecture/mihomo.md）。
;;;
;;; Ownership：Guix System + Shepherd 独占 Mihomo 进程生命周期
;;; （TUN、route/auto-redirect、proxy runtime、external-controller）。
;;; Noctalia Mihomo Control 只经 Clash REST API 控制运行中的实例，
;;; 不启动/停止/更新 binary。binary 唯一 owner 是 Rosenthal channel
;;; 的 mihomo package（pin 1.19.30，(rosenthal packages networking)）。
;;;
;;; 设计决策（2026-08-27 审计，方案 B）：不复用 Rosenthal
;;; clash-service-type（(rosenthal services child-error)）——本服务
;;; 与其通用语义有三处实质差异：运行时 secret-bearing 配置路径
;;; （-f /run/mihomo/config.yaml，Rosenthal 只支持 store file-like
;;; symlink 到 -d/config.yaml）、对 ordinary-secrets-ready 与
;;; mihomo-config-ready 的依赖（Rosenthal 硬编码 '(loopback
;;; networking)）、providers 子目录的 machine-state 持久化。三处
;;; 都需要动其 shepherd/activation，且仓库规则禁止为新 API repin
;;; channel（AGENT.md §6）——因此自建 thin service，只复用 mihomo
;;; package。Rosenthal 的通用改进（config-file / shepherd-requirement
;;; 字段，默认行为不变）记录为未来上游 PR 目标。
;;;
;;; 路径契约（与 (guixcfg system mihomo config) 共享常量）：
;;;   immutable:  /gnu/store/...-mihomo-template.yaml（公开模板）
;;;   runtime:    /run/mihomo/config.yaml（materializer 合成，0600 root）
;;;   secret:     /run/guixcfg-secrets-ordinary/system/mihomo-subscription.url
;;;   persistent: /var/lib/clash/providers（machine-state bind，0700）
;;;   log:        /var/log/mihomo.log（ephemeral，root 0640）
;;; 不整体 persist /var/lib/clash；config.yaml 不在 -d 下（-f 指定）。
;;;
;;; secret 边界（诚实声明，见 docs/architecture/mihomo.md）：
;;;   - ciphertext colocate 本模块（secrets/mihomo-subscription.url.age，
;;;     单份密文、stable recipient 加密，所有设备共用——无 host 层）；
;;;   - plaintext subscription URL 不进 Git、不进 /gnu/store；
;;;   - runtime config 在 /run（0600 root）；
;;;   - Mihomo provider fetch 失败时，上游实现会把完整 URL（含 query
;;;     token）写入 error log（VM 实测 "[Provider] airport pull
;;;     error: Get \"http://...\": EOF"）——当前接受：日志 ephemeral
;;;     且仅 root 可读；
;;;   - 不声称 secret "绝不落盘"。

(define-module (guixcfg system mihomo service)
               #:use-module (gnu services)          ; service、service-type、service-extension
               #:use-module (gnu services shepherd) ; shepherd-service
               #:use-module (gnu system shadow)     ; user-group
               #:use-module (guix gexp)             ; local-file、program-file、file-append
               #:use-module (guix modules)          ; source-module-closure
               #:use-module (rosenthal packages networking) ; mihomo
               #:use-module (guixcfg utils module-closure)  ; guixcfg-module-select?
               #:use-module (guixcfg system mihomo config)
               #:use-module (guixcfg security secrets) ; secret-decl（subscription secret colocate）
               #:use-module (guixcfg system machine-state-persistence) ; %machine-state-root
               #:export (%mihomo-data-directory
                         %mihomo-log-file
                         %mihomo-template-file
                         %mihomo-data-persistence-rule
                         mihomo-config-program
                         mihomo-config-shepherd-service
                         mihomo-daemon-shepherd-service
                         mihomo-activation
                         mihomo-account
                         mihomo-service-type
                         mihomo-service
                         %mihomo-secrets))

(define %mihomo-data-directory "/var/lib/clash")
(define %mihomo-log-file "/var/log/mihomo.log")

;; 公开模板（colocate；构建期随 closure 进 store，无 secret）。
(define %mihomo-template-file
  (local-file "template.yaml" "mihomo-template.yaml"))

;; subscription URL 的 secret-decl（单一 owner = 本模块；所有设备共用
;; 同一密文，target-name 契约见 (guixcfg system mihomo config) 的
;; %mihomo-secret-path）。测试 sentinel 密文（example.invalid 假订阅）；
;; 真实订阅 URL 由宿主用 stable recipient 重加密后替换本文件。
(define %mihomo-secrets
  (list (secret-decl
         (name 'mihomo-subscription)
         (scope 'system)
         (domain 'ordinary)
         (source (local-file "secrets/mihomo-subscription.url.age"
                             "mihomo-subscription.url.age"))
         (target-name "mihomo-subscription.url")
         (owner-user "root")
         (mode #o400))))

;; mihomo 数据目录的 machine-state 持久化（整个 -d，不拆分）：
;; /persist/system/state/mihomo/clash → bind → /var/lib/clash。
;; 覆盖 providers cache（订阅节点列表）与 cache.db（选中节点/组
;; 状态）——两者都是 machine-owned mutable state，重启后都应保留
;; （2026-08-28：只持久化 providers 时，选中节点每 boot 重置）。
;; backing 与 consumer 的 0700 由 mihomo-activation 强制（generic
;; mechanism 只 mkdir 0755；Mihomo 以 0644 写 provider cache 文件，
;; 隔离靠不可遍历的 0700 parent——用户设计契约）。
(define %mihomo-data-persistence-rule
  (machine-state-persistence-rule
   (name 'mihomo-data)
   (backing "mihomo/clash")
   (consumer "/var/lib/clash")))

;; ────────────────────────────────────────────────────────────
;; runtime config materializer（只做 config composition，不下载订阅）
;; ────────────────────────────────────────────────────────────

(define (mihomo-config-program)
  "生成 mihomo-config 程序：读公开模板（store）与已解密的
subscription URL（/run，root 0400），按 (guixcfg system
mihomo-config) 的 fail-closed 契约合成完整配置，原子写入
/run/mihomo/config.yaml（0700 目录 / 0600 文件）。不联网、不用
shell；URL 绝不进 argv/environment/日志（成功日志只报路径）。"
  (program-file
   "mihomo-config"
   (with-imported-modules
    (source-module-closure '((guixcfg system mihomo config)
                             (guixcfg utils atomic-file)
                             (srfi srfi-13)
                             (ice-9 string-fun)
                             (ice-9 match)
                             (ice-9 textual-ports))
                           #:select? guixcfg-module-select?)
    #~(begin
        (use-modules (guixcfg system mihomo config)
                     (guixcfg utils atomic-file)
                     (srfi srfi-13)
                     (ice-9 string-fun)
                     (ice-9 match)
                     (ice-9 textual-ports))
        (define (fail! msg)
          (format (current-error-port) "mihomo-config: ~a~%" msg)
          (exit 1))
        (let* ((template
                (catch 'system-error
                  (lambda ()
                    (call-with-input-file #$%mihomo-template-file
                      get-string-all))
                  (lambda args
                    (fail! (string-append "cannot read template "
                                          #$%mihomo-template-file)))))
               (secret
                (catch 'system-error
                  (lambda ()
                    (call-with-input-file %mihomo-secret-path
                      get-string-all))
                  (lambda args
                    (fail! (string-append "cannot read secret file "
                                          %mihomo-secret-path))))))
          (catch 'mihomo-config-error
            (lambda ()
              (let ((config (compose-mihomo-config template secret)))
                (unless (file-exists? %mihomo-runtime-dir)
                  (mkdir %mihomo-runtime-dir))
                (chmod %mihomo-runtime-dir #o700)
                ;; .new 与最终文件都在 0700 目录内：原子提交窗口
                ;; 内（rename 与 chmod 之间）文件不可被他人穿越读取。
                (atomic-write-file! %mihomo-runtime-config-path
                                    (lambda (port)
                                      (display config port)))
                (chmod %mihomo-runtime-config-path #o600)
                (display (string-append "mihomo-config: wrote "
                                        %mihomo-runtime-config-path
                                        "\n"))))
            (lambda (key msg)
              (fail! msg))))))))

;; ────────────────────────────────────────────────────────────
;; Shepherd：materializer one-shot + mihomo daemon
;; ────────────────────────────────────────────────────────────

(define (mihomo-config-shepherd-service)
  "one-shot：解密后的 secret 就位后合成 runtime config。provision
mihomo-config-ready——mihomo daemon 显式依赖它（声明式 ordering，
无启动竞态）。"
  (list (shepherd-service
         (provision '(mihomo-config-ready))
         (requirement '(ordinary-secrets-ready))
         (one-shot? #t)
         (respawn? #f)
         (documentation
          "Compose the runtime Mihomo configuration from the public \
template and the decrypted subscription URL into \
/run/mihomo/config.yaml (root 0600).")
         (start #~(lambda ()
                    (zero? (system* #$(mihomo-config-program)))))
         (stop #~(const #f)))))

(define (mihomo-daemon-shepherd-service)
  "Mihomo daemon：-d 数据目录 + -f runtime config。requirement 显式
含 mihomo-config-ready（materializer）与 networking（NM 就绪）；
respawn 保持 shepherd 默认；stop 走 make-kill-destructor（SIGTERM
→ Mihomo 自清理 TUN/route/nftables）。"
  (list (shepherd-service
         (provision '(mihomo))
         (requirement '(loopback networking mihomo-config-ready))
         (documentation
          "Run Mihomo as the system transparent proxy (TUN with \
auto-route/auto-redirect; external controller on loopback only).")
         (start #~(make-forkexec-constructor
                   (list #$(file-append mihomo "/bin/mihomo")
                         "-d" #$%mihomo-data-directory
                         "-f" #$%mihomo-runtime-config-path)
                   #:group "clash"
                   #:log-file #$%mihomo-log-file))
         (stop #~(make-kill-destructor)))))

;; ────────────────────────────────────────────────────────────
;; activation / account / service type
;; ────────────────────────────────────────────────────────────

(define (mihomo-activation)
  "系统 activation：数据目录、providers 及其 machine-state backing
的 mkdir + 0700（backing 由 generic machine-state activation 以 0755
创建，本 activation 无论先后都最终强制 0700——隔离 0644 的 provider
cache 文件）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (let ((providers
                                   (string-append #$%mihomo-data-directory
                                                  "/providers"))
                                  (backing
                                   (string-append #$%machine-state-root
                                                  "/mihomo/providers")))
                              (mkdir-p #$%mihomo-data-directory)
                              (mkdir-p providers)
                              (mkdir-p backing)
                              (chmod providers #o700)
                              (chmod backing #o700)))))

(define (mihomo-account)
  "clash 系统组（daemon 以 root 运行 + clash 组；TUN 需要 root，
不引入专用用户）。"
  (list (user-group
         (name "clash")
         (system? #t))))

(define mihomo-service-type
  (service-type
   (name 'mihomo)
   (extensions
    (list (service-extension shepherd-root-service-type
                             (lambda (config)
                               (append (mihomo-config-shepherd-service)
                                       (mihomo-daemon-shepherd-service))))
          (service-extension activation-service-type
                             (lambda (config) (mihomo-activation)))
          (service-extension account-service-type
                             (lambda (config) (mihomo-account)))))
   (default-value #t)
   (description
    "Run Mihomo as the system transparent proxy with a runtime-composed
configuration (subscription URL never in the store).")))

(define (mihomo-service)
  "Mihomo system service 实例（Phase 1 固定契约，无可配置字段）。"
  (service mihomo-service-type #t))
