;;; Flatpak 显式运维操作层（docs/architecture/flatpak.md（operations））。
;;;
;;; 本模块是唯一允许调用联网 flatpak CLI 的地方，且只被 tools/ 入口
;;; 消费——绝不 import 于 Home/System service/activation 模块
;;; （composition 测试静态断言；reconfigure/boot/login 零网络
;;; 不变量）。
;;;
;;; 所有 repository-managed 操作显式 --user（无 system installation、
;;; 无 /var/lib/flatpak）；语义：
;;;   sync    只增不删（remote 缺失 add；app 缺失 install + optional
;;;           pin deploy）；不 update 已装、不 uninstall、不 gc
;;;   status  默认完全离线（--refresh 才 remote-info，失败显示
;;;           unknown，不破坏本地输出）
;;;   update  目标 = selection ∩ installed ∩ unpinned，显式 ref 列表；
;;;           绝无无参全 installation update
;;;   update-runtimes  枚举 installed runtimes 后显式 ref 更新
;;;   remove  显式 uninstall（userdata 保留；remove ≠ purge）
;;;   gc      orphan runtimes + repair（显式维护，不挂 hook）
;;;
;;; remote reconciliation：remote 不存在 → add（.flatpakrepo
;;; descriptor 由 flatpak 抓取解析——联网只在显式 sync）；存在且
;;; effective url == repository-url → no-op；不一致 → fail + 可操作
;;; 诊断，绝不自动 remote-modify/delete（不静默改 trust root）。
;;;
;;; runtime 输出 English printable ASCII（AGENT.md §11）。

(define-module (guixcfg flatpak reconcile)
               #:use-module ((guix build utils) #:select (invoke which))
               #:use-module (guixcfg utils process) ; invoke-capture（stdout 捕获）
               #:use-module (guixcfg flatpak model)
               #:use-module (guixcfg flatpak registry)
               #:use-module (ice-9 format)
               #:use-module (srfi srfi-1)  ; member、find、filter、filter-map
               #:use-module (srfi srfi-13) ; string-split、string-tokenize、string-trim-both、string-prefix?
               #:export (flatpak-binary
                         flatpak-remotes-alist
                         flatpak-check-remote!
                         flatpak-ensure-remote!
                         flatpak-list-installed-apps
                         flatpak-list-installed-runtime-refs
                         flatpak-install-app!
                         flatpak-installed-commit
                         flatpak-sync
                         flatpak-status
                         flatpak-update
                         flatpak-update-runtimes
                         flatpak-remove
                         flatpak-gc))

(define (flatpak-binary)
  "flatpak 可执行文件绝对路径（PATH 解析；工具入口把它注入
FLATPAK_BINARY，install 时 desktop entry export 需要绝对路径）。
缺失 → fail fast。"
  (or (which "flatpak")
      (error "flatpak executable not found in PATH \
(is it installed in the system profile?)")))

;;; ── remotes ────────────────────────────────────────────────

(define (flatpak-remotes-alist)
  "已配置 user remotes 的 ((name . url) ...)（'flatpak remotes
--user --columns=name,url'）。"
  (map (lambda (line)
         (let ((tokens (string-tokenize line)))
           (if (>= (length tokens) 2)
             (cons (car tokens) (cadr tokens))
             (cons line ""))))
       (filter (negate string-null?)
               (map string-trim-both
                    (string-split
                     (invoke-capture "flatpak" "remotes" "--user"
                                     "--columns=name,url")
                     #\newline)))))

(define (flatpak-check-remote! remote)
  "REMOTE 存在且 effective url == repository-url → #t；不存在 →
#f；存在但 url 不一致 → error（actionable diagnostic）。绝不
静默修改 trust root。"
  (let* ((name (symbol->string (flatpak-remote-name remote)))
         (url (assoc-ref (flatpak-remotes-alist) name)))
    (cond ((not url) #f)
          ((string=? url (flatpak-remote-repository-url remote)) #t)
          (else
           (error (string-append
                   "Flatpak remote '" name
                   "' differs from the repository declaration.\n"
                   "Expected: " (flatpak-remote-repository-url remote)
                   "\n"
                   "Actual:   " url "\n\n"
                   "Refusing to modify an existing remote automatically.\n"
                   "Use an explicit remote maintenance operation \
to replace or modify it."))))))

(define (flatpak-ensure-remote! remote)
  "remote 缺失 → remote-add --user --if-not-exists NAME LOCATION
（.flatpakrepo descriptor 联网抓取只发生在显式 sync）；已存在 →
drift 检查（见 flatpak-check-remote!）。"
  (unless (flatpak-check-remote! remote)
    (format #t "Adding Flatpak remote '~a'...~%"
            (symbol->string (flatpak-remote-name remote)))
    (invoke "flatpak" "remote-add" "--user" "--if-not-exists"
            (symbol->string (flatpak-remote-name remote))
            (flatpak-remote-location remote))))

;;; ── installed state ────────────────────────────────────────

(define (flatpak-list-installed-apps)
  "已安装 app-id 列表（'flatpak list --user --app'；runtime 天然
不参与 desired/unmanaged 判断）。"
  (filter (negate string-null?)
          (map string-trim-both
               (string-split
                (invoke-capture "flatpak" "list" "--user" "--app"
                                "--columns=application")
                #\newline))))

(define (flatpak-list-installed-runtime-refs)
  "已安装 runtime 的 '<id>//<branch>' ref 列表（'flatpak list --user
--runtime --columns=application,branch'）。"
  (filter-map
   (lambda (line)
     (let ((tokens (string-tokenize line)))
       (and (>= (length tokens) 2)
            (string-append (car tokens) "//" (cadr tokens)))))
   (filter (negate string-null?)
           (map string-trim-both
                (string-split
                 (invoke-capture "flatpak" "list" "--user" "--runtime"
                                 "--columns=application,branch")
                 #\newline)))))

(define (flatpak-installed-commit id)
  "已安装 app 的本地 commit（'flatpak info --user --show-commit'）；
未安装/失败 → #f。"
  (false-if-exception
   (let ((out (string-trim-both
               (invoke-capture "flatpak" "info" "--user" "--show-commit"
                               id))))
     (if (string-prefix? "Commit: " out)
       (string-drop out (string-length "Commit: "))
       out))))

;;; ── sync（ensure only）─────────────────────────────────────

(define (flatpak-install-app! app)
  "install（只增）+ optional commit pin deploy。pinned Flatpak
1.16.6：install 无 --commit 参数——pin 经两步：
  install <remote> <ref> → update --commit=<H> <ref>。
app pin 不隐含 runtime pin（不实现 dependency lockfile）。"
  (let ((ref (flatpak-application-ref app))
        (remote (symbol->string (flatpak-application-remote app))))
    (format #t "Installing ~a from '~a'...~%" ref remote)
    (invoke "flatpak" "install" "--user" "-y" "--noninteractive"
            remote ref)
    (let ((commit (flatpak-application-commit app)))
      (when commit
        (format #t "Deploying pinned commit ~a for ~a...~%" commit ref)
        (invoke "flatpak" "update" "--user"
                (string-append "--commit=" commit) ref)))))

(define* (flatpak-sync #:key (remotes %flatpak-remotes)
                            (applications %flatpak-applications)
                            (selection %flatpak-selection))
  "ensure declared remotes + ensure selected apps installed。
只增不删：不 update 已装 app、不 remove 未声明 app、不 gc。
返回本次安装的 <flatpak-application> 列表。"
  (for-each flatpak-ensure-remote! remotes)
  (let* ((selected (flatpak-select-applications selection applications))
         (missing (flatpak-reconcile-plan
                   selected (flatpak-list-installed-apps))))
    (for-each flatpak-install-app! missing)
    missing))

;;; ── status ─────────────────────────────────────────────────

(define* (flatpak-status #:key (refresh? #f)
                              (applications %flatpak-applications)
                              (selection %flatpak-selection))
  "表格输出（catalog 顺序）。默认完全离线（本地 list/info）；
REFRESH? 才 remote-info（失败显示 unknown，不修改状态、不破坏
本地输出）。"
  (let ((installed (flatpak-list-installed-apps)))
    (format #t "NAME\tID\tSELECTED\tINSTALLED\tBRANCH\tDECLARED-COMMIT\tINSTALLED-COMMIT~@[~a~]~%"
            (if refresh? "\tREMOTE-COMMIT" ""))
    (for-each
     (lambda (app)
       (let* ((id (flatpak-application-id app))
              (selected? (memq (flatpak-application-name app) selection))
              (installed? (member id installed))
              (installed-commit (and installed?
                                     (flatpak-installed-commit id)))
              (remote-commit
               (and refresh?
                    (false-if-exception
                     (string-trim-both
                      (invoke-capture
                       "flatpak" "remote-info" "--user" "--show-commit"
                       (symbol->string (flatpak-application-remote app))
                       (flatpak-application-ref app)))))))
         (format #t "~a\t~a\t~a\t~a\t~a\t~a\t~a~@[~a~]~%"
                 (flatpak-application-name app)
                 id
                 (if selected? "yes" "no")
                 (if installed? "yes" "no")
                 (flatpak-application-branch app)
                 (or (flatpak-application-commit app) "-")
                 (or installed-commit "-")
                 (if refresh?
                   (string-append "\t" (or remote-commit "unknown"))
                   ""))))
     applications)))

;;; ── update ─────────────────────────────────────────────────

(define* (flatpak-update #:key (applications %flatpak-applications)
                              (selection %flatpak-selection))
  "更新目标 = selection ∩ installed ∩ unpinned（commit #f），显式
ref 列表逐个 update。绝无无参全 installation update；commit pinned
app 默认不进目标；无目标 → clean no-op。"
  (let* ((installed (flatpak-list-installed-apps))
         (targets
          (filter
           (lambda (app)
             (and (member (flatpak-application-id app) installed)
                  (not (flatpak-application-commit app))))
           (flatpak-select-applications selection applications))))
    (if (null? targets)
      (format #t "No unpinned selected applications to update.~%")
      (apply invoke "flatpak" "update" "--user" "-y"
             (map flatpak-application-ref targets)))))

(define (flatpak-update-runtimes)
  "显式更新已安装 runtimes（pinned 1.16.6 无'更新全部 runtime'的
裸开关——先枚举再逐 ref）。无 runtime → clean no-op。"
  (let ((refs (flatpak-list-installed-runtime-refs)))
    (if (null? refs)
      (format #t "No installed runtimes to update.~%")
      (apply invoke "flatpak" "update" "--user" "-y" refs))))

;;; ── remove / gc ────────────────────────────────────────────

(define* (flatpak-remove name #:key (applications %flatpak-applications))
  "显式 uninstall（logical name，catalog fail-fast 解析）。只卸
ref：~/.var/app/<id> 数据与 persistence rule 保留（remove ≠ purge；
catalog 删除是 purge 之后的 teardown 最后一步）。"
  (let ((app (find (lambda (a) (eq? name (flatpak-application-name a)))
                   applications)))
    (unless app
      (error "unknown flatpak application (remove takes a catalog \
logical name)"
             name (map flatpak-application-name applications)))
    (invoke "flatpak" "uninstall" "--user" "-y"
            (flatpak-application-id app))
    (format #t "Removed ~a (~a). User data under ~/.var/app/~a \
is preserved.~%"
            name (flatpak-application-id app)
            (flatpak-application-id app))))

(define (flatpak-gc)
  "显式维护：orphan runtimes（uninstall --unused）+ installation
repair。不挂 boot/reconfigure/activation hook。"
  (invoke "flatpak" "uninstall" "--unused" "--user" "-y")
  (invoke "flatpak" "repair" "--user"))
