;;; Flatpak 平台模型（docs/architecture/flatpak.md）：remote /
;;; application / override 记录 + 校验 + selection resolver +
;;; reconcile plan 纯函数 + override GKeyFile renderer。
;;;
;;; Catalog/Selection 分离是生命周期结构要求（desired lifecycle ≠
;;; persistence lifecycle）：
;;;   - Catalog（registry 的 %flatpak-applications）= identity +
;;;     resource ownership：logical name、app-id、remote、branch、
;;;     optional commit pin、optional repo-owned override；
;;;     persistence rules 从 Catalog 派生；
;;;   - Selection（registry 的 %flatpak-selection）= sync 应该
;;;     ensure 哪些应用；selection ⊆ catalog（fail-fast）。
;;;   selection removal 非破坏性（ref 不卸载、bind 仍在）；
;;;   catalog definition removal 是 teardown 最后一步（purge 之后）。
;;;
;;; commit pin（可选例外，默认 #f = branch tracking）：Flatpak
;;; commit 不等价 Guix source pin（remote 可 prune 历史 commit、无
;;; 自建 mirror），因此不设 mandatory lockfile、不自动记录 installed
;;; commit；pin 语义见 docs/architecture/flatpak.md（updates）。
;;;
;;; Override = complete-file ownership：repo 生成整个 GKeyFile
;;; （deterministic renderer），不 merge、不持续 mutation；只建模
;;; v1 真实需要的键，不复制 Flatpak 整套 [Context] schema。

(define-module (guixcfg flatpak model)
               #:use-module (guix records)
               #:use-module (srfi srfi-1)  ; every、member、filter、delete-duplicates
               #:use-module (srfi srfi-13) ; string-every、string-contains、string-index
               #:use-module (srfi srfi-14) ; char-whitespace?
               #:export (<flatpak-remote>
                         flatpak-remote make-flatpak-remote flatpak-remote?
                         flatpak-remote-name
                         flatpak-remote-location
                         flatpak-remote-repository-url
                         flatpak-remote-comment
                         <flatpak-application>
                         flatpak-application make-flatpak-application flatpak-application?
                         flatpak-application-name
                         flatpak-application-id
                         flatpak-application-remote
                         flatpak-application-branch
                         flatpak-application-commit
                         flatpak-application-overrides
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
                         valid-flatpak-application?
                         validate-flatpak-catalog!
                         validate-flatpak-selection!
                         flatpak-select-applications
                         flatpak-application-ref
                         flatpak-reconcile-plan
                         flatpak-render-override-file))

;;; ── remote ────────────────────────────────────────────────
;;; location（bootstrap）与 repository-url（effective）是两个语义：
;;;   - location：首次建立 remote/trust 时传给
;;;     `flatpak remote-add NAME LOCATION`（repo URL 直接写配置；
;;;     .flatpakrepo descriptor URL 会被 flatpak 抓取解析——联网，
;;;     只发生在显式 sync）；
;;;   - repository-url：remote 建立后应呈现的 effective repo URL，
;;;     用于无需再取 descriptor 的 drift 检查
;;;     （flatpak remotes --user --columns=name,url）。
;;; 两者不能混淆直接比较（descriptor URL ≠ effective repo URL）。
(define-record-type* <flatpak-remote>
                     flatpak-remote make-flatpak-remote
                     flatpak-remote?
                     (name flatpak-remote-name)                  ; symbol
                     (location flatpak-remote-location)          ; string（bootstrap LOCATION）
                     (repository-url flatpak-remote-repository-url) ; string（drift 检查基准）
                     (comment flatpak-remote-comment             ; string（信任决策说明）
                              (default "")))

;;; ── application ───────────────────────────────────────────
(define-record-type* <flatpak-application>
                     flatpak-application make-flatpak-application
                     flatpak-application?
                     (name flatpak-application-name)          ; symbol：logical name（selection 的键）
                     (id flatpak-application-id)              ; string：Flatpak app-id
                     (remote flatpak-application-remote)      ; symbol：remote name（查 remote 表）
                     (branch flatpak-application-branch)      ; string："stable" 等
                     (commit flatpak-application-commit       ; #f = branch tracking；string = optional pin
                             (default #f))
                     (overrides flatpak-application-overrides ; #f = user/Flatseal owns；
                             (default #f)))                   ; <flatpak-override> = repo owns whole file

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
  "#f（branch tracking）或非空 hex 字符串（OSTree commit）。"
  (or (not commit)
      (and (string? commit)
           (> (string-length commit) 0)
           (string-every hex-char? commit))))

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
       (let ((location (flatpak-remote-location remote))
             (repository-url (flatpak-remote-repository-url remote)))
         (and (string? location) (> (string-length location) 0)
              (string? repository-url) (> (string-length repository-url) 0)
              (string? (flatpak-remote-comment remote))))))

(define (valid-flatpak-override? overrides)
  (or (not overrides)
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
                       (flatpak-override-system-bus overrides))))))

(define (valid-flatpak-application? app remote-names)
  "APP 结构合法且 remote ∈ REMOTE-NAMES（symbol 列表）。"
  (and (flatpak-application? app)
       (symbol? (flatpak-application-name app))
       (valid-flatpak-app-id? (flatpak-application-id app))
       (memq (flatpak-application-remote app) remote-names)
       (valid-flatpak-branch? (flatpak-application-branch app))
       (valid-flatpak-commit? (flatpak-application-commit app))
       (valid-flatpak-override? (flatpak-application-overrides app))))

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
