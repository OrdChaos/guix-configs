;;; Flatpak 显式运维操作层（docs/architecture/flatpak.md（operations））。
;;;
;;; 本模块是唯一允许调用联网 flatpak CLI 的地方，且只被 Blue 的
;;; `flatpak` 命令消费（blueprint.scm 的 thin dispatch）——绝不
;;; import 于 Home/System service/activation 模块（composition 测试
;;; 静态断言；reconfigure/boot/login 零网络不变量）。
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
               #:use-module (ice-9 match)
               #:use-module (srfi srfi-1)  ; member、find、filter、filter-map
               #:use-module (srfi srfi-13) ; string-split、string-tokenize、string-trim-both、string-prefix?
               #:export (flatpak-binary
                         flatpak-binary-candidates
                         flatpak-remotes-alist
                         flatpak-remote-by-name
                         flatpak-check-remote!
                         flatpak-bootstrap-remote!
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
                         flatpak-gc
                         ;; Blue flatpak 命令的 invocation 契约与
                         ;; dry-run plan（只读；不读 Blue state）
                         %flatpak-actions
                         flatpak-actions
                         flatpak-validate-action-arguments
                         flatpak-sync-plan
                         flatpak-update-plan
                         flatpak-update-runtimes-plan
                         flatpak-remove-plan
                         flatpak-replace-remote-plan
                         flatpak-gc-commands))

(define (flatpak-binary-candidates)
  ;; 有序候选：会话 PATH 解析优先（显式覆盖），随后 guix 标准安装
  ;; 位置——VM 的 system profile（flatpak 由 system/packages.scm
  ;; 声明于此）与用户 profile。
  (cons (which "flatpak")
        (list "/run/current-system/profile/bin/flatpak"
              (string-append (getenv "HOME")
                             "/.guix-profile/bin/flatpak"))))

(define (flatpak-binary)
  "flatpak 可执行文件绝对路径（工具入口把它注入 FLATPAK_BINARY，
install 时 desktop entry export 需要绝对路径）。ssh 非 login shell
不 source /etc/profile，PATH 里没有 system profile，只靠 PATH 解析
会误报缺失（VM 内 sudo 的 secure_path 恰好有它，造成'加 sudo 才
可用'的假象——而且 sudo 会把操作落到 root 的 user installation，
完全错误）；因此按候选表显式回退到 guix 标准安装位置。本机没有
flatpak（Flatpak 子系统只在 VM 内提供）：全部候选缺失 → fail
fast。"
  (or (find (lambda (path)
              (and (string? path) (file-exists? path)))
            (flatpak-binary-candidates))
      (error "flatpak executable not found \
(searched PATH, /run/current-system/profile and ~/.guix-profile); \
flatpak operations are VM-side only")))

;;; ── remotes ────────────────────────────────────────────────

(define (flatpak-remote-by-name name)
  "REMOTE name → <flatpak-remote>（registry 查表；未知名 fail-fast
并列出可用名——remote-replace 的解析入口）。"
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

(define (flatpak-remote-set-url! remote)
  "把 remote 的 effective URL 强制设为声明的 repository-url。
pinned 1.16.6 实测：remote-add --from 抓取 summary 时会【无条件】
应用 summary 里的 xa.redirect-url（Flathub 的 summary 自带
redirect 回 dl.flathub.org——镜像 URL 会被静默改写回官方；
--no-follow_redirect flag 在 --from 路径上无效，VM -vv 实测），而
remote-modify --url 不抓 summary、redirect 跟随是显式 opt-in
（--follow-redirect，默认不跟）。已实测：落定后 install/update/
remote-ls 的 summary 抓取不会再次改写 URL。"
  (invoke "flatpak" "remote-modify" "--user"
          (string-append "--url="
                         (flatpak-remote-repository-url remote))
          (symbol->string (flatpak-remote-name remote))))

(define* (flatpak-bootstrap-remote! remote)
         "领域操作：从零建立 remote 并落定为声明状态——封装 pinned
Flatpak 1.16.6 的 bootstrap 细节，调用方不需要理解：
    1. remote-add --from NAME DESCRIPTOR-URL
       （flatpak 下载官方 descriptor、导入其当前 GPGKey——trust
       lifecycle 由官方持有：续期/轮换在本次 bootstrap 自然获取；
       descriptor 下载失败 = bootstrap 失败，绝不 fallback 到镜像
       descriptor / 缓存 / --no-gpg-verify / 裸 URL）；
    2. remote-modify --url=<repository-url>（canonicalize——add
       阶段抓取 summary 时会【无条件】应用其 xa.redirect-url
       （Flathub 的 summary 指回官方，镜像 URL 被改写；
       --no-follow_redirect flag 在 --from 路径上无效，VM -vv
       实测），必须此步落定声明 transport）。
Partial-failure rollback：modify 失败时只删除【本次调用刚创建】
的 remote（调用前提 = flatpak-check-remote! 为 #f），避免留下
redirect 改写后的非声明状态等下次 sync 才发现 drift。绝不删除
本操作之前已存在的 remote。"
         (let ((name (symbol->string (flatpak-remote-name remote))))
           (invoke "flatpak" "remote-add" "--user" "--if-not-exists"
                   "--from" name
                   (flatpak-remote-descriptor-url remote))
           (catch #t
             (lambda ()
               (flatpak-remote-set-url! remote))
             (lambda args
               (false-if-exception
                (invoke "flatpak" "remote-delete" "--user" name))
               (apply throw args)))))

(define (flatpak-ensure-remote! remote)
  "remote 缺失 → flatpak-bootstrap-remote!（建立 + canonicalize）；
已存在 → drift 检查（见 flatpak-check-remote!），绝不自动修改。"
  (unless (flatpak-check-remote! remote)
    (format #t "Adding Flatpak remote '~a'...~%"
            (symbol->string (flatpak-remote-name remote)))
    (flatpak-bootstrap-remote! remote)))

(define (flatpak-replace-remote! remote)
  "显式换源（唯一允许删除 remote 的入口；不自动调用——换源 = 修改
已有 mutable state，必须由用户显式发起）：remote-delete（如存在）
→ bootstrap 重建（官方 descriptor → key 重导入 → transport 落定）。
trust 边界仍在：命令本身是显式的 destructive acknowledgment，sync
永远走不到这里。"
  (let ((name (symbol->string (flatpak-remote-name remote))))
    (when (assoc-ref (flatpak-remotes-alist) name)
      (format #t "Replacing Flatpak remote '~a' (explicit)...~%" name)
      (invoke "flatpak" "remote-delete" "--user" name))
    (flatpak-ensure-remote! remote)))

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
                       (selection %flatpak-selection))
         "ensure declared remotes + ensure selected apps installed。
只增不删：不 update 已装 app、不 remove 未声明 app、不 gc。
sync 对【全部 declared remotes】做 ensure（缺即 bootstrap——新
remote 首次引入 sync 即自动建立；drift 则 fail-loud），不依赖
selected apps 是否引用它们（声明即意图）。返回本次安装的
<flatpak-application> 列表。

逐项报告（含 no-op）：已收敛时也要有输出——静默成功与失败在
终端上不可区分，且会诱导用户误以为必须 sudo（sudo 落到 root
的 user installation 反而「有输出」）。"
         ;; remotes：已声明 → no-op 行；缺失 → ensure（bootstrap
         ;; 自打印 Adding…）。
         (for-each (lambda (remote)
                     (when (flatpak-check-remote! remote)
                       (format #t "remote ~a: already declared (no-op)~%"
                               (flatpak-remote-name remote))))
                   remotes)
         (for-each flatpak-ensure-remote! remotes)
         (let* ((selected (flatpak-select-applications selection applications))
                (installed (flatpak-list-installed-apps))
                (missing (flatpak-reconcile-plan selected installed)))
           (for-each (lambda (app)
                       (when (member (flatpak-application-id app) installed)
                         (format #t "~a: already installed (no-op)~%"
                                 (flatpak-application-ref app))))
                     selected)
           (for-each flatpak-install-app! missing)
           (format #t "sync complete: ~a remotes ensured, ~a application(s) installed~%"
                   (length remotes) (length missing))
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
  (for-each (lambda (argv) (apply invoke argv)) (flatpak-gc-commands)))

;;; ── Blue flatpak 命令的 invocation 契约与 dry-run plan ────────
;;;
;;; 本小节是 Flatpak 域对外的调用契约（单一事实源）：action 集合、
;;; 参数形态校验、以及 dry-run 需要的只读 plan。全部不读 Blue
;;; state（dry-run 判定由 blueprint 做）；plan 函数只做真实只读
;;; 查询 + 纯计算，绝不修改 Flatpak 状态——blue -n flatpak 的
;;; “绝不 mutate”由它们保证。

;; action 注册表：name → 是否纯只读查询（只有 status）。
(define %flatpak-actions
  '((sync . #f)
    (status . #t)
    (update . #f)
    (update-runtimes . #f)
    (remove . #f)
    (remote-replace . #f)
    (gc . #f)))

(define (flatpak-actions)
  "支持的全部 action 名（字符串，canonical 顺序）。"
  (map (compose symbol->string car) %flatpak-actions))

(define (flatpak-validate-action-arguments action rest)
  "校验 ACTION 与剩余位置参数的形态，返回规范化形态或 #f（非法）。
status 接受可选 --refresh；remove/remote-replace 恰好一个参数；其余
零个。未知 action 不 fallback。"
  (match (cons action rest)
         (("status") '(status ()))
         (("status" "--refresh") '(status (refresh)))
         (("sync") '(sync ()))
         (("update") '(update ()))
         (("update-runtimes") '(update-runtimes ()))
         (("remove" name) `(remove (,name)))
         (("remote-replace" name) `(remote-replace (,name)))
         (("gc") '(gc ()))
         (_ #f)))

(define (flatpak-sync-plan remotes applications selection)
  "sync 的只读 plan：remote 缺失清单 + 待安装 app 清单（每项一行）。
不修改任何状态；remote drift 由 flatpak-check-remote! 照常
fail-loud（dry-run 也报 drift）。"
  (append
   (map (lambda (r)
          (if (flatpak-check-remote! r)
            (format #f "remote ~a: already declared (no-op)"
                    (flatpak-remote-name r))
            (format #f "would add remote ~a (descriptor ~a; transport ~a)"
                    (flatpak-remote-name r)
                    (flatpak-remote-descriptor-url r)
                    (flatpak-remote-repository-url r))))
        remotes)
   (map (lambda (app)
          (format #f "would install ~a from ~a~a"
                  (flatpak-application-ref app)
                  (flatpak-application-remote app)
                  (if (flatpak-application-commit app)
                    (format #f " (pin ~a)" (flatpak-application-commit app))
                    "")))
        (flatpak-reconcile-plan
         (flatpak-select-applications selection applications)
         (flatpak-list-installed-apps)))))

(define (flatpak-update-plan applications selection)
  "update 的只读 plan：selection ∩ installed ∩ unpinned 的 ref 列表。"
  (let ((installed (flatpak-list-installed-apps)))
    (map flatpak-application-ref
         (filter (lambda (app)
                   (and (member (flatpak-application-id app) installed)
                        (not (flatpak-application-commit app))))
                 (flatpak-select-applications selection applications)))))

(define (flatpak-update-runtimes-plan)
  "update-runtimes 的只读 plan：已安装 runtime 的 ref 列表。"
  (flatpak-list-installed-runtime-refs))

(define (flatpak-remove-plan name applications)
  "remove 的只读 plan：catalog 解析目标 app；未知 logical name 与
remove 相同的 fail-fast（dry-run 也必须参数校验）。"
  (or (find (lambda (a) (eq? name (flatpak-application-name a)))
            applications)
      (error "unknown flatpak application (remove takes a catalog \
logical name)"
             name (map flatpak-application-name applications))))

(define (flatpak-replace-remote-plan remote)
  "remote-replace 的只读 plan：当前 effective url（未配置 → #f）。"
  (assoc-ref (flatpak-remotes-alist)
             (symbol->string (flatpak-remote-name remote))))

(define (flatpak-gc-commands)
  "gc 的两条 subprocess argv。pinned Flatpak 不提供 unused runtime
枚举查询，dry-run 只能 command preview——因此 argv 是单一事实源
（flatpak-gc 与 blueprint 的预览共用）。"
  '(("flatpak" "uninstall" "--unused" "--user" "-y")
    ("flatpak" "repair" "--user")))
