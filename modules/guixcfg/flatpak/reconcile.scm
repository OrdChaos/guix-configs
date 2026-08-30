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
                         flatpak-remote-by-name
                         flatpak-check-remote!
                         flatpak-ensure-remote!
                         flatpak-replace-remote!
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

(define (flatpak-remote-by-name name)
  "REMOTE name → <flatpak-remote>（registry 查表；未知名 fail-fast
并列出可用名——remotes-replace 的解析入口）。"
  (or (find (lambda (r) (eq? name (flatpak-remote-name r)))
            %flatpak-remotes)
      (error "unknown flatpak remote"
             name (map flatpak-remote-name %flatpak-remotes))))

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

(define* (flatpak-ensure-remote! remote #:key (flatpakrepo #f))
  "remote 缺失 → remote-add --user --if-not-exists NAME LOCATION；
已存在 → drift 检查（见 flatpak-check-remote!），绝不自动修改。

FLATPAKREPO 提供时（本地 vendored descriptor，内含 GPGKey 与
effective Url）用 --from 引导：本地文件、零联网抓取、keyring 一次
到位——裸 URL 引导不会自动导入 keyring（pinned 1.16.6 实测首次
install 报 'public key not found'）。"
  (unless (flatpak-check-remote! remote)
    (format #t "Adding Flatpak remote '~a'...~%"
            (symbol->string (flatpak-remote-name remote)))
    (if flatpakrepo
      ;; remote-add 语法：NAME 在前、LOCATION 在后；--from 时
      ;; LOCATION 是本地配置文件（顺序实测修正：文件在前会让
      ;; flatpak 把 name 当文件加载）。
      (invoke "flatpak" "remote-add" "--user" "--if-not-exists"
              "--from"
              (symbol->string (flatpak-remote-name remote))
              flatpakrepo)
      (invoke "flatpak" "remote-add" "--user" "--if-not-exists"
              (symbol->string (flatpak-remote-name remote))
              (flatpak-remote-location remote)))))

(define* (flatpak-replace-remote! remote #:key (flatpakrepo #f))
  "显式换源（唯一允许删除 remote 的入口；不自动调用——换源 = 修改
已有 mutable state，必须由用户显式发起）：remote-delete（如存在）
→ 按声明重新 remote-add。trust 边界仍在：命令本身是显式的
destructive acknowledgment，sync 永远走不到这里。"
  (let ((name (symbol->string (flatpak-remote-name remote))))
    (when (assoc-ref (flatpak-remotes-alist) name)
      (format #t "Replacing Flatpak remote '~a' (explicit)...~%" name)
      (invoke "flatpak" "remote-delete" "--user" name))
    (flatpak-ensure-remote! remote #:flatpakrepo flatpakrepo)))

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
app pin 不隐含 runtime pin（不实现 dependency lockfile）。

有意不带 --noninteractive：该 flag 会关掉下载进度条（终端用户
看不到 runtime 大体积拉取的任何反馈，像卡死）。-y 已自动应答
全部提问；stdout 非 tty 时 flatpak 自行不画进度——脚本场景不受
影响。"
  (let ((ref (flatpak-application-ref app))
        (remote (symbol->string (flatpak-application-remote app))))
    (format #t "Installing ~a from '~a'...~%" ref remote)
    (invoke "flatpak" "install" "--user" "-y" remote ref)
    (let ((commit (flatpak-application-commit app)))
      (when commit
        (format #t "Deploying pinned commit ~a for ~a...~%" commit ref)
        (invoke "flatpak" "update" "--user"
                (string-append "--commit=" commit) ref)))))

(define* (flatpak-sync #:key (remotes %flatpak-remotes)
                            (applications %flatpak-applications)
                            (selection %flatpak-selection)
                            (flatpakrepo #f))
  "ensure declared remotes + ensure selected apps installed。
只增不删：不 update 已装 app、不 remove 未声明 app、不 gc。
FLATPAKREPO（本地 vendored descriptor）传给 ensure-remote 做带
keyring 的引导。返回本次安装的 <flatpak-application> 列表。"
  (for-each (lambda (remote)
              (flatpak-ensure-remote! remote #:flatpakrepo flatpakrepo))
            remotes)
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
