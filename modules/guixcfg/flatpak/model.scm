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
;;; application update policy（显式领域语义，替代裸 commit 字段）：
;;;   'track-branch                   默认：跟随 branch
;;;   (flatpak-commit-pin "<hex>")    optional 例外 pin（必须注释
;;;                                   理由）：Flatpak commit 不等价
;;;                                   Guix source pin（remote 可
;;;                                   prune 历史 commit），因此不设
;;;                                   mandatory lockfile。
;;; Extension 当前仅允许 'track-branch：update-runtimes 会批量更新
;;; runtime refs，无法兑现 commit pin 时必须 fail closed。
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
                         <flatpak-extension>
                         flatpak-extension make-flatpak-extension flatpak-extension?
                         flatpak-extension-name
                         flatpak-extension-id
                         flatpak-extension-remote
                         flatpak-extension-branch
                         flatpak-extension-update-policy
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
                          valid-flatpak-extension?
                          validate-flatpak-catalog!
                          validate-flatpak-extension-catalog!
                          validate-flatpak-selection!
                          validate-flatpak-extension-selection!
                          flatpak-select-applications
                          flatpak-select-extensions
                          flatpak-application-ref
                          flatpak-extension-ref
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

;;; ── extension ──────────────────────────────────────────────
(define-record-type* <flatpak-extension>
                     flatpak-extension make-flatpak-extension
                     flatpak-extension?
                     (name flatpak-extension-name)              ; symbol：logical name（selection 的键）
                     (id flatpak-extension-id)                  ; string：Flatpak ref id
                     (remote flatpak-extension-remote)          ; symbol：remote name（查 remote 表）
                     (branch flatpak-extension-branch)          ; string：与 runtime/app ABI 绑定（如 "25.08"）
                     (update-policy flatpak-extension-update-policy ; extension 仅支持 'track-branch
                                    (default 'track-branch)))

;;; ── extension（auxiliary ref；docs/architecture/flatpak.md
;;; （application model））────────────────────────────────────
;;; Flatpak 生态有一类不是 application 的 ref：Vulkan layer
;;; （org.freedesktop.Platform.VulkanLayer.*，runtime extension）
;;; 与 app 专属工具（com.valvesoftware.Steam.CompatibilityTool.*，
;;; app extension）。它们：无 desktop 入口、无 ~/.var state、无
;;; override——安装进 user installation 后由 runtime/app 的
;;; extension point 自动挂载。建模为独立 record（复用 application
;;; 的 identity/ref 校验），persistence/override 明确不存在；sync
;;; 把 selected extension 显式 pin，防止 GC/autoprune 删除。

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

(define (ascii-alpha? c)
  (or (and (char>=? c #\a) (char<=? c #\z))
      (and (char>=? c #\A) (char<=? c #\Z))))

(define (ascii-digit? c)
  (and (char>=? c #\0) (char<=? c #\9)))

(define (valid-app-id-segment? segment final?)
  (and (> (string-length segment) 0)
       (not (ascii-digit? (string-ref segment 0)))
       (string-every (lambda (c)
                       (or (ascii-alpha? c) (ascii-digit? c)
                           (char=? c #\_)
                           (and final? (char=? c #\-))))
                     segment)))

(define (valid-flatpak-app-id? id)
  "ID 遵循 Flatpak name 语法：3+ 个 ASCII 段、≤255 字符、段首
非数字；'-' 只允许出现在最后一段。"
  (and (string? id)
       (<= 1 (string-length id) 255)
       (let ((segments (string-split id #\.)))
         (and (>= (length segments) 3)
              (every (lambda (entry)
                       (valid-app-id-segment? (car entry) (cdr entry)))
                     (map (lambda (segment index)
                            (cons segment (= index (1- (length segments)))))
                          segments (iota (length segments))))))))

(define (valid-flatpak-branch? branch)
  "BRANCH 是 Flatpak branch：ASCII [A-Za-z0-9_.-]+，且不以 '.' 开头。"
  (and (string? branch)
       (> (string-length branch) 0)
       (not (char=? #\. (string-ref branch 0)))
       (string-every (lambda (c)
                       (or (ascii-alpha? c) (ascii-digit? c)
                           (char=? c #\_) (char=? c #\.) (char=? c #\-)))
                     branch)))

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
                 (and (string? e) (> (string-length e) 0)
                      (not (string-any (lambda (c)
                                         (or (char=? c #\newline)
                                             (char=? c #\return)
                                             (char=? c #\nul)))
                                       e))))
               f)))

(define (valid-bus-policy? e)
  "Bus policy 条目形态 'org.name=talk|own|see|none'。"
  (and (string? e)
       (let ((i (string-index e #\=)))
         (and i (> i 0)
              (member (substring e (1+ i))
                      '("talk" "own" "see" "none"))))))

(define (valid-environment-entry? e)
  "environment 条目形态 'VAR=VALUE'；VAR 为 POSIX 风格变量名。"
  (and (string? e)
       (let ((i (string-index e #\=)))
          (and i (> i 0)
               (let ((name (substring e 0 i))
                     (value (substring e (1+ i))))
                 (and (or (ascii-alpha? (string-ref name 0))
                          (char=? #\_ (string-ref name 0)))
                      (string-every (lambda (c)
                                      (or (ascii-alpha? c) (ascii-digit? c)
                                          (char=? c #\_)))
                                    name)
                      (not (string-any (lambda (c)
                                         (or (char=? c #\newline)
                                             (char=? c #\return)
                                             (char=? c #\nul)))
                                       value))))))))

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

(define (valid-flatpak-extension? ext remote-names)
  "EXT 结构合法且 remote ∈ REMOTE-NAMES。extension 无
override/persistence 字段（机制上不存在，不是省略）。"
  (and (flatpak-extension? ext)
       (symbol? (flatpak-extension-name ext))
       (valid-flatpak-app-id? (flatpak-extension-id ext))
       (memq (flatpak-extension-remote ext) remote-names)
       (valid-flatpak-branch? (flatpak-extension-branch ext))
       ;; update-runtimes 会更新已安装 runtime refs，无法可靠保留
       ;; extension commit pin；在实现完整 lock 语义前 fail closed。
       (eq? 'track-branch (flatpak-extension-update-policy ext))))

(define (validate-flatpak-extension-catalog! remotes extensions)
  "EXTENSIONS（catalog）fail-fast 校验：结构合法、remote 已知、
logical name 唯一、branch-qualified ref 唯一。违反抛错。"
  (let ((remote-names (map flatpak-remote-name remotes)))
    (for-each (lambda (ext)
                (unless (valid-flatpak-extension? ext remote-names)
                  (error "invalid flatpak extension" ext)))
              extensions)
    (let ((names (map flatpak-extension-name extensions)))
      (unless (= (length names) (length (delete-duplicates names)))
        (error "duplicate flatpak extension logical name" names)))
    (let ((refs (map flatpak-extension-ref extensions)))
      (unless (= (length refs) (length (delete-duplicates refs string=?)))
        (error "duplicate flatpak extension ref" refs)))
    #t))

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
fail-fast。"
  (validate-flatpak-selection! names apps)
  (filter (lambda (a) (memq (flatpak-application-name a) names))
          apps))

(define (validate-flatpak-extension-selection! names extensions)
  "NAMES（extension selection）⊆ EXTENSIONS（catalog）的 logical
name 集合；违反 fail-fast 并列出未知名与可用名。"
  (let ((catalog-names (map flatpak-extension-name extensions)))
    (for-each (lambda (name)
                (unless (memq name catalog-names)
                  (error "flatpak extension selection refers to unknown extension"
                         name catalog-names)))
              names)
    #t))

(define (flatpak-select-extensions names extensions)
  "把 extension selection NAMES 解析为 EXTENSIONS 中对应
<flatpak-extension> 列表（按 catalog 顺序）。未知 name fail-fast。"
  (validate-flatpak-extension-selection! names extensions)
  (filter (lambda (e) (memq (flatpak-extension-name e) names))
          extensions))

(define (flatpak-application-ref app)
  "App 的 Flatpak ref：'<app-id>//<branch>'。"
  (string-append (flatpak-application-id app)
                 "//" (flatpak-application-branch app)))

(define (flatpak-extension-ref ext)
  "Extension 的 Flatpak ref：'<ext-id>//<branch>'。"
  (string-append (flatpak-extension-id ext)
                 "//" (flatpak-extension-branch ext)))

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
  "DESIRED（selected <flatpak-application> 列表）中 id//branch 不在
INSTALLED（已安装 id//branch 字符串列表）的应用 = 需安装列表（保持
desired 顺序）。只做 desired − installed；绝不计划 uninstall/
update/GC；runtime refs 不参与（INSTALLED 由 'flatpak list --user
--app' 产出，天然不含 runtime）。"
  (filter (lambda (app)
            (not (member (flatpak-application-ref app) installed)))
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
        (cons "filesystems" flatpak-override-filesystems)))

(define (escape-keyfile-string s list-element?)
  "按 GKeyFile string 规则转义；LIST-ELEMENT? 额外转义 ';'。"
  (let loop ((chars (string->list s)) (first? #t) (out '()))
    (if (null? chars)
      (string-concatenate-reverse out)
      (let* ((c (car chars))
             (escaped (cond ((char=? c #\\) "\\\\")
                        ((char=? c #\tab) "\\t")
                        ((and first? (char=? c #\space)) "\\s")
                        ((and list-element? (char=? c #\;)) "\\;")
                        (else (string c)))))
        (loop (cdr chars) #f (cons escaped out))))))

(define (escape-keyfile-entry s)
  (escape-keyfile-string s #t))

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

(define (render-environment-section entries)
  "Flatpak override 的环境变量是 [Environment] 中逐项 KEY=VALUE，
不是 [Context] 的分号列表。"
  (if (null? entries)
    ""
    (string-append
     "[Environment]\n"
     (string-join
      (map (lambda (entry)
             (let ((i (string-index entry #\=)))
               (string-append (substring entry 0 i) "="
                              (escape-keyfile-string
                               (substring entry (1+ i)) #f))))
           entries)
      "\n")
     "\n")))

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
                  (render-environment-section
                   (flatpak-override-environment overrides))
                  (render-bus-section "Session Bus Policy"
                                     (flatpak-override-session-bus
                                      overrides))
                 (render-bus-section "System Bus Policy"
                                     (flatpak-override-system-bus
                                      overrides))))))
    (string-join parts "\n")))
