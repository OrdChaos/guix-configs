;;; Flatpak 平台模型（docs/architecture/flatpak.md）：remote /
;;; application / override 记录 + 校验 + selection resolver +
;;; reconcile plan 纯函数 + override GKeyFile renderer + bootstrap
;;; descriptor 生成。
;;;
;;; Application model（定义 = 应用是什么；selection = 设备要哪些）：
;;;   每个 Flatpak 应用是自包含 definition（applications/<name>.scm），
;;;   拥有自己的 identity / ref metadata / update policy / override
;;;   policy / persistence intent；registry 只做聚合（见
;;;   (guixcfg flatpak registry)），投影由 service（persistence +
;;;   overrides，offline）与 reconcile（install/update plan，
;;;   mutable/network）从 definition 推导。
;;;
;;; Remote model（identity / bootstrap authority / transport）：
;;;   identity           = remote name（'flathub）
;;;   bootstrap authority = descriptor-url：官方 .flatpakrepo URL——
;;;     我们明确信任官方 descriptor 当前提供的 GPGKey（trust
;;;     lifecycle 由 upstream 持有：续期/轮换在下次 bootstrap /
;;;     remote-replace 时自然获取，无需仓库维护 key material、
;;;     fingerprint 或过期日期）
;;;   transport          = repository-url（当前：SJTU 镜像裸 OSTree
;;;     URL——镜像只改变 transport，不改变 identity 与 trust）
;;;   本模块不生成任何 descriptor、不 vendor 任何 key 文件。
;;;
;;; update policy（显式领域语义，替代裸 commit 字段）：
;;;   'track-branch                   默认：跟随 branch
;;;   (flatpak-commit-pin "<hex>")    optional 例外 pin（必须注释
;;;                                   理由）：Flatpak commit 不等价
;;;                                   Guix source pin（remote 可
;;;                                   prune 历史 commit），因此不设
;;;                                   mandatory lockfile。
;;;
;;; override policy（complete-file ownership，不 merge）：
;;;   'external                       仓库不拥有 override 文件
;;;                                   （user/Flatseal owns）
;;;   (managed-overrides <flatpak-override>)
;;;                                   仓库生成完整文件（home-files
;;;                                   store symlink，derived state）
;;;
;;; persistence intent：
;;;   默认 ~/.var/app/<id> 由 application ID 推导（service 投影）；
;;;   extra-persistence 只声明默认之外的例外（(consumer backing)
;;;   两元素列表，backing 相对 flatpak/apps/ 命名空间）。

(define-module (guixcfg flatpak model)
               #:use-module (guix records)
               #:use-module (guixcfg utils paths) ; valid-relative-path?（extra-persistence 契约共享）
               #:use-module (srfi srfi-1)  ; every、member、filter、delete-duplicates
               #:use-module (srfi srfi-13) ; string-every、string-contains、string-index
               #:use-module (srfi srfi-14) ; char-whitespace?
               #:export (<flatpak-remote>
                         flatpak-remote make-flatpak-remote flatpak-remote?
                         flatpak-remote-name
                         flatpak-remote-descriptor-url
                         flatpak-remote-repository-url
                         flatpak-remote-comment
                         <flatpak-application>
                         flatpak-application make-flatpak-application flatpak-application?
                         flatpak-application-name
                         flatpak-application-id
                         flatpak-application-remote
                         flatpak-application-branch
                         flatpak-application-update-policy
                         flatpak-application-override-policy
                         flatpak-application-extra-persistence
                         <flatpak-override>
                         flatpak-override make-flatpak-override flatpak-override?
                         flatpak-override-sockets
                         flatpak-override-devices
                         flatpak-override-shared
                         flatpak-override-features
                         flatpak-override-filesystems
                         flatpak-override-environment
                         flatpak-override-session-bus
                         flatpak-override-system-bus
                         valid-flatpak-remote?
                         valid-flatpak-app-id?
                         valid-flatpak-branch?
                         valid-flatpak-commit?
                         valid-flatpak-update-policy?
                         valid-flatpak-override-policy?
                         valid-flatpak-application?
                         validate-flatpak-catalog!
                         validate-flatpak-selection!
                         flatpak-select-applications
                         flatpak-application-ref
                         flatpak-application-commit
                         flatpak-application-pinned?
                         flatpak-application-managed-overrides
                         flatpak-reconcile-plan
                         flatpak-render-override-file))

;;; ── remote（identity / trust / transport）──────────────────

(define-record-type* <flatpak-remote>
                     flatpak-remote make-flatpak-remote
                     flatpak-remote?
                     (name flatpak-remote-name)                      ; symbol：identity
                     (descriptor-url flatpak-remote-descriptor-url)  ; string：官方 .flatpakrepo URL（bootstrap + trust authority）
                     (repository-url flatpak-remote-repository-url)  ; string：desired transport（drift 检查基准 + canonicalize 目标）
                     (comment flatpak-remote-comment                 ; string（信任决策说明）
                              (default "")))

;;; ── application ───────────────────────────────────────────
(define-record-type* <flatpak-application>
                     flatpak-application make-flatpak-application
                     flatpak-application?
                     (name flatpak-application-name)              ; symbol：logical name（selection 的键）
                     (id flatpak-application-id)                  ; string：Flatpak app-id
                     (remote flatpak-application-remote)          ; symbol：remote name（查 remote 表）
                     (branch flatpak-application-branch)          ; string："stable" 等
                     (update-policy flatpak-application-update-policy ; 'track-branch | (flatpak-commit-pin "<hex>")
                                    (default 'track-branch))
                     (override-policy flatpak-application-override-policy ; 'external | (managed-overrides <flatpak-override>)
                                     (default 'external))
                     (extra-persistence flatpak-application-extra-persistence ; list of (consumer . backing)
                                       (default '())))

;;; ── override（只建模 v1 真实字段；非 Flatpak [Context] 全集）──
;;; 各字段是 string 列表：元素可为 "!xxx"（撤销 manifest 基线项）。
;;; session-bus/system-bus 元素形态 "org.name=talk|own|see|none"。
;;; environment 元素形态 "VAR=VALUE"（禁止换行）。
(define-record-type* <flatpak-override>
                     flatpak-override make-flatpak-override
                     flatpak-override?
                     (sockets flatpak-override-sockets (default '()))
                     (devices flatpak-override-devices (default '()))
                     (shared flatpak-override-shared (default '()))
                     (features flatpak-override-features (default '()))
                     (filesystems flatpak-override-filesystems (default '()))
                     (environment flatpak-override-environment (default '()))
                     (session-bus flatpak-override-session-bus (default '()))
                     (system-bus flatpak-override-system-bus (default '())))

;;; ── 校验 ──────────────────────────────────────────────────

(define (app-id-segment-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (char=? c #\_) (char=? c #\-)))

(define (valid-flatpak-app-id? id)
  "ID 是合法 Flatpak app-id：≥2 个 '.' 分隔的非空段，每段只含
字母数字、'_'、'-'（D-Bus 风格分段名）。"
  (and (string? id)
       (> (string-length id) 0)
       (let ((segments (string-split id #\.)))
         (and (>= (length segments) 2)
              (every (lambda (s)
                       (and (> (string-length s) 0)
                            (string-every app-id-segment-char? s)))
                     segments)))))

(define (valid-flatpak-branch? branch)
  "BRANCH 是非空字符串且不含 '/' 与空白（Flatpak ref 语法）。"
  (and (string? branch)
       (> (string-length branch) 0)
       (not (string-contains branch "/"))
       (not (string-any char-whitespace? branch))))

(define (hex-char? c)
  (or (char-numeric? c)
      (and (char>=? c #\a) (char<=? c #\f))
      (and (char>=? c #\A) (char<=? c #\F))))

(define (valid-flatpak-commit? commit)
  "非空 hex 字符串（OSTree commit）。"
  (and (string? commit)
       (> (string-length commit) 0)
       (string-every hex-char? commit)))

(define (non-empty-string-list? f)
  (and (list? f)
       (every (lambda (e)
                (and (string? e) (> (string-length e) 0)))
              f)))

(define (valid-bus-policy? e)
  "Bus policy 条目形态 'org.name=talk|own|see|none'。"
  (and (string? e)
       (let ((i (string-index e #\=)))
         (and i (> i 0)
              (member (substring e (1+ i))
                      '("talk" "own" "see" "none"))))))

(define (valid-environment-entry? e)
  "environment 条目形态 'VAR=VALUE'，无换行。"
  (and (string? e)
       (let ((i (string-index e #\=)))
         (and i (> i 0)
              (not (string-contains e "\n"))))))

(define (valid-flatpak-remote? remote)
  (and (flatpak-remote? remote)
       (symbol? (flatpak-remote-name remote))
       (let ((descriptor (flatpak-remote-descriptor-url remote))
             (url (flatpak-remote-repository-url remote)))
         (and (string? descriptor) (> (string-length descriptor) 0)
              (string? url) (> (string-length url) 0)
              (string? (flatpak-remote-comment remote))))))

(define (valid-flatpak-override? overrides)
  (and (flatpak-override? overrides)
       (non-empty-string-list? (flatpak-override-sockets overrides))
       (non-empty-string-list? (flatpak-override-devices overrides))
       (non-empty-string-list? (flatpak-override-shared overrides))
       (non-empty-string-list? (flatpak-override-features overrides))
       (non-empty-string-list? (flatpak-override-filesystems overrides))
       (and (list? (flatpak-override-environment overrides))
            (every valid-environment-entry?
                   (flatpak-override-environment overrides)))
       (and (list? (flatpak-override-session-bus overrides))
            (every valid-bus-policy?
                   (flatpak-override-session-bus overrides)))
       (and (list? (flatpak-override-system-bus overrides))
            (every valid-bus-policy?
                   (flatpak-override-system-bus overrides)))))

(define (valid-flatpak-update-policy? policy)
  "'track-branch（默认跟随 branch）或
(flatpak-commit-pin \"<hex>\")（optional pin）。"
  (or (eq? 'track-branch policy)
      (and (pair? policy)
           (= 2 (length policy))
           (eq? 'flatpak-commit-pin (car policy))
           (valid-flatpak-commit? (cadr policy)))))

(define (valid-flatpak-override-policy? policy)
  "'external（user/Flatseal owns）或
(managed-overrides <flatpak-override>)（repo owns whole file）。"
  (or (eq? 'external policy)
      (and (pair? policy)
           (= 2 (length policy))
           (eq? 'managed-overrides (car policy))
           (valid-flatpak-override? (cadr policy)))))

(define (valid-flatpak-extra-persistence? extras)
  "(consumer backing) 两元素 proper list 的集合（与 seeds /
configuration-variants 的 (target source) 约定一致）：consumer 是
HOME 相对路径、backing 是 flatpak/apps/ 命名空间相对路径（共享
valid-relative-path? 契约）。默认 persistence（~/.var/app/<id>）
不在此声明，由 service 投影从 ID 推导。"
  (and (list? extras)
       (every (lambda (entry)
                (and (list? entry)
                     (= 2 (length entry))
                     (valid-relative-path? (car entry))
                     (valid-relative-path? (cadr entry))))
              extras)))

(define (valid-flatpak-application? app remote-names)
  "APP 结构合法且 remote ∈ REMOTE-NAMES（symbol 列表）。"
  (and (flatpak-application? app)
       (symbol? (flatpak-application-name app))
       (valid-flatpak-app-id? (flatpak-application-id app))
       (memq (flatpak-application-remote app) remote-names)
       (valid-flatpak-branch? (flatpak-application-branch app))
       (valid-flatpak-update-policy?
        (flatpak-application-update-policy app))
       (valid-flatpak-override-policy?
        (flatpak-application-override-policy app))
       (valid-flatpak-extra-persistence?
        (flatpak-application-extra-persistence app))))

(define (validate-flatpak-catalog! remotes apps)
  "REMOTES/APPS（Catalog）fail-fast 校验：remote 名字唯一、remote
结构合法；logical name 唯一、app-id 唯一、remote 已知、app 结构
合法。违反抛错（可诊断，含冲突项）。"
  (for-each (lambda (remote)
              (unless (valid-flatpak-remote? remote)
                (error "invalid flatpak remote" remote)))
            remotes)
  (let ((remote-names (map flatpak-remote-name remotes)))
    (unless (= (length remote-names)
               (length (delete-duplicates remote-names)))
      (error "duplicate flatpak remote name" remote-names))
    (for-each (lambda (app)
                (unless (valid-flatpak-application? app remote-names)
                  (error "invalid flatpak application" app)))
              apps)
    (unless (= (length (map flatpak-application-name apps))
               (length (delete-duplicates (map flatpak-application-name apps))))
      (error "duplicate flatpak application logical name"
             (map flatpak-application-name apps)))
    (unless (= (length (map flatpak-application-id apps))
               (length (delete-duplicates (map flatpak-application-id apps))))
      (error "duplicate flatpak application id"
             (map flatpak-application-id apps)))
    #t))

(define (validate-flatpak-selection! names apps)
  "NAMES（selection）⊆ APPS（catalog）的 logical name 集合；违反
fail-fast 并列出未知名与可用名。"
  (let ((catalog-names (map flatpak-application-name apps)))
    (for-each (lambda (name)
                (unless (memq name catalog-names)
                  (error "flatpak selection refers to unknown application"
                         name catalog-names)))
              names)
    #t))

(define (flatpak-select-applications names apps)
  "把 selection NAMES（logical name 列表）解析为 APPS（catalog）中
对应 <flatpak-application> 列表（按 catalog 顺序）。未知 name
fail-fast。host 层只知道 logical name，不知道 app-id。"
  (validate-flatpak-selection! names apps)
  (filter (lambda (a) (memq (flatpak-application-name a) names))
          apps))

(define (flatpak-application-ref app)
  "App 的 Flatpak ref：'<app-id>//<branch>'。"
  (string-append (flatpak-application-id app)
                 "//" (flatpak-application-branch app)))

(define (flatpak-application-commit app)
  "update-policy 的 commit 视图：#f = track branch；string = pin。"
  (let ((policy (flatpak-application-update-policy app)))
    (if (eq? 'track-branch policy)
      #f
      (cadr policy))))

(define (flatpak-application-pinned? app)
  "update-policy 是否 pin 了具体 commit。"
  (not (eq? 'track-branch
            (flatpak-application-update-policy app))))

(define (flatpak-application-managed-overrides app)
  "override-policy 的 managed 视图：#f = external（user/Flatseal
owns）；<flatpak-override> = repo owns whole file。"
  (let ((policy (flatpak-application-override-policy app)))
    (if (eq? 'external policy)
      #f
      (cadr policy))))

;;; ── reconcile plan（纯函数，只增不删）─────────────────────

(define (flatpak-reconcile-plan desired installed)
  "DESIRED（selected <flatpak-application> 列表）中 app-id 不在
INSTALLED（已安装 app-id 字符串列表）的应用 = 需安装列表（保持
desired 顺序）。只做 desired − installed；绝不计划 uninstall/
update/GC；runtime refs 不参与（INSTALLED 由 'flatpak list --user
--app' 产出，天然不含 runtime）。"
  (filter (lambda (app)
            (not (member (flatpak-application-id app) installed)))
          desired))

;;; ── override renderer（deterministic complete GKeyFile）────
;;; 键名/组名对应 pinned Flatpak 1.16.6 的 overrides 文件格式
;;; （GKeyFile；[Context] 组 + [Session Bus Policy]/[System Bus
;;; Policy] 组；列表元素以 ';' 连接，'!' 前缀撤销 manifest 基线项）。
;;; 实施时以 `guix build --source flatpak` 的 app/flatpak-dir.c /
;;; app/flatpak-run.c 交叉核对；VM acceptance 用
;;; `flatpak override --show --user <id>` 回读验证。

;; 确定性字段顺序（fixture 测试与实现共同固定）。值必须是 accessor
;; 过程本身（可直接 apply），不是 symbol。
(define %flatpak-override-context-order
  (list (cons "shared" flatpak-override-shared)
        (cons "sockets" flatpak-override-sockets)
        (cons "devices" flatpak-override-devices)
        (cons "features" flatpak-override-features)
        (cons "filesystems" flatpak-override-filesystems)
        (cons "environment" flatpak-override-environment)))

(define (escape-keyfile-entry s)
  "GKeyFile 列表元素转义：'\\' → '\\\\'，';' → '\\;'（换行已在
校验层拒绝）。"
  (string-fold
   (lambda (c acc)
     (string-append acc
                    (cond ((char=? c #\\) "\\\\")
                          ((char=? c #\;) "\\;")
                          (else (string c)))))
   "" s))

(define (render-context-lines overrides)
  "非空字段 → (\"key=values\") 行（字段顺序固定；列表顺序 = 声明
顺序）。列表值以 ';' 连接并带尾分号——与 flatpak CLI 自己写入的
override 文件格式逐字节一致（GLib keyfile 解析两端等价；
`flatpak override --show` 回读交叉验证）。"
  (filter-map
   (lambda (entry)
     (let* ((key (car entry))
            (accessor (cdr entry))
            (values (accessor overrides)))
       (and (pair? values)
            (string-append key "="
                           (string-join
                            (map escape-keyfile-entry values)
                            ";")
                           ";"))))
   %flatpak-override-context-order))

(define (render-bus-section title policies)
  "TITLE 组 + 每行 'name=value'（声明顺序）。空 → 空串。"
  (if (null? policies)
    ""
    (string-append "[" title "]\n"
                   (string-join policies "\n") "\n")))

(define (flatpak-render-override-file overrides)
  "把 <flatpak-override> 渲染为完整 override 文件文本（确定性）。
所有字段为空 → 空串（不产生文件；user/Flatseal owns）。"
  (let* ((context-lines (render-context-lines overrides))
         (parts
          (filter
           (negate string-null?)
           (list (if (null? context-lines)
                   ""
                   (string-append "[Context]\n"
                                  (string-join context-lines "\n")
                                  "\n"))
                 (render-bus-section "Session Bus Policy"
                                     (flatpak-override-session-bus
                                      overrides))
                 (render-bus-section "System Bus Policy"
                                     (flatpak-override-system-bus
                                      overrides))))))
    (string-join parts "\n")))
