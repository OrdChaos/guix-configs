;;; GSettings model / aggregation / serializer / session service 测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 覆盖：
;;;   record 校验（空 schema/key/value 拒绝）；
;;;   ownership 硬规则（重复 (schema,key) 拒绝——同值也拒绝、错误
;;;     含 owner 信息；不同 schema 同 key / 同 schema 不同 key 允许）；
;;;   appearance 保留域（6 个动态外观键冲突拒绝）；
;;;   aggregation（synthetic application 的 owner pairs）；
;;;   serializer（schema→dconf path、bool/int/string 透传、确定性
;;;     排序、重复序列化 byte-identical）；
;;;   session service 结构（one-shot / respawn? #f / dbus 依赖 /
;;;     无 shell 字符串）。
;;;
;;; 不访问用户真实 dconf；不 invoke 真实 gsettings/dconf。

(use-modules (guixcfg gsettings model)
             (guixcfg gsettings serialize)
             (guixcfg gsettings home-service) ; gsettings-reconcile-service（wrapper/契约断言）
             (guixcfg apps model)       ; make-application、applications-gsettings
             (guixcfg apps registry)    ; %applications（唯一启用事实源）
             (guixcfg apps gnome-text-editor definition) ; %gnome-text-editor（first consumer）
             (guixcfg home user)        ; %guix-home（service 结构断言）
             (gnu home)                 ; home-environment-services（standalone 自足，不依赖套件模块上下文）
             (gnu home services shepherd) ; home-shepherd-service-type
             (gnu services)             ; fold-services
             (guix gexp)                ; gexp->approximate-sexp、lower-object
             (guix store)               ; open-connection（store identity 断言）
             (guix monads)              ; run-with-store
             (guix derivations)         ; derivation-file-name
             (ice-9 rdelim)             ; read-string（wrapper 源码契约断言）
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (fails-with? substring thunk)
  "THUNK 抛错且错误参数文本含 SUBSTRING → #t；不抛错 → #f。"
  (catch #t
    (lambda () (thunk) #f)
    (lambda args
      (string-contains (format #f "~s" args) substring))))

(define (make-setting schema key value)
  (gsettings-setting (schema schema) (key key) (value value)))

(test-begin "gsettings")

;; ── record 校验 ────────────────────────────────────────────

(test-assert "record: valid setting passes"
             (valid-gsettings-setting?
              (make-setting "org.a.B" "k" "true")))

(test-assert "record: empty schema rejected"
             (not (valid-gsettings-setting?
                   (make-setting "" "k" "true"))))

(test-assert "record: empty key rejected"
             (not (valid-gsettings-setting?
                   (make-setting "org.a.B" "" "true"))))

(test-assert "record: empty value rejected"
             (not (valid-gsettings-setting?
                   (make-setting "org.a.B" "k" ""))))

(test-assert "record: non-string value rejected"
             (not (valid-gsettings-setting?
                   (make-setting "org.a.B" "k" 42))))

;; ── ownership 硬规则 ───────────────────────────────────────

(test-assert "ownership: single owner passes"
             (validate-gsettings-ownership!
              (list (cons 'foo (make-setting "org.a.B" "k" "true")))))

(test-assert "ownership: duplicate (schema,key) rejected even with same value"
             (fails-with? "duplicate GSettings ownership"
                          (lambda ()
                            (validate-gsettings-ownership!
                             (list (cons 'foo (make-setting "org.a.B" "k" "true"))
                                   (cons 'bar (make-setting "org.a.B" "k" "true")))))))

(test-assert "ownership: duplicate error reports all owners"
             (fails-with? "foo"
                          (lambda ()
                            (validate-gsettings-ownership!
                             (list (cons 'foo (make-setting "org.a.B" "k" "true"))
                                   (cons 'bar (make-setting "org.a.B" "k" "false")))))))

(test-assert "ownership: different schemas same key allowed"
             (validate-gsettings-ownership!
              (list (cons 'foo (make-setting "org.a.B" "k" "true"))
                    (cons 'bar (make-setting "org.a.C" "k" "true")))))

(test-assert "ownership: same schema different keys allowed"
             (validate-gsettings-ownership!
              (list (cons 'foo (make-setting "org.a.B" "k1" "true"))
                    (cons 'bar (make-setting "org.a.B" "k2" "true")))))

(test-assert "ownership: invalid setting reports owner"
             (fails-with? "foo"
                          (lambda ()
                            (validate-gsettings-ownership!
                             (list (cons 'foo (make-setting "" "k" "true")))))))

(test-assert "ownership: appearance-reserved key rejected"
             (fails-with? "appearance-sync"
                          (lambda ()
                            (validate-gsettings-ownership!
                             (list (cons 'foo
                                         (make-setting "org.gnome.desktop.interface"
                                                       "color-scheme"
                                                       "prefer-dark")))))))

(test-assert "ownership: current repository registry passes validation"
             (validate-gsettings-ownership!
              (applications-gsettings %applications)))

;; ── first consumer（gnome-text-editor）──────────────────────
;; schema/key 以 VM 实测的 pinned 48.3 org.gnome.TextEditor 为准
;; （gsettings list-keys / range；indent-style 枚举 'tab'|'space'）。

(test-equal "consumer: gnome-text-editor declares exactly the 7 pinned keys"
            '("custom-font" "highlight-current-line" "indent-style"
                            "show-line-numbers" "show-right-margin" "style-scheme"
                            "use-system-font")
            (map gsettings-setting-key
                 (application-gsettings %gnome-text-editor)))

(test-equal "consumer: single owner contribution captured by aggregation"
            'gnome-text-editor
            (caar (filter (lambda (entry)
                            (eq? (car entry) 'gnome-text-editor))
                          (applications-gsettings %applications))))

(test-equal "consumer: serialized keyfile is byte-identical to the declared projection"
            "[org/gnome/TextEditor]\ncustom-font='Monospace 11'\nhighlight-current-line=true\nindent-style='space'\nshow-line-numbers=true\nshow-right-margin=false\nstyle-scheme='Adwaita'\nuse-system-font=false\n"
            (serialize-gsettings-keyfile
             (application-gsettings %gnome-text-editor)))

(test-assert "consumer: no appearance-reserved key declared"
             (not (any (lambda (setting)
                         (assoc (cons (gsettings-setting-schema setting)
                                      (gsettings-setting-key setting))
                                %appearance-owned-gsettings-keys))
                       (application-gsettings %gnome-text-editor))))

;; ── aggregation ────────────────────────────────────────────

(define %setting-1 (make-setting "org.a.B" "k1" "true"))
(define %setting-2 (make-setting "org.a.C" "k2" "'x'"))
(define %app-a (application
                (name 'app-a)
                (gsettings (list %setting-1))))
(define %app-b (application
                (name 'app-b)
                (gsettings (list %setting-2))))
(define %app-no-gsettings (application (name 'app-no-gsettings)))

(test-equal "aggregation: owner pairs in declaration order, empty contribution skipped"
            (list (cons 'app-a %setting-1) (cons 'app-b %setting-2))
            (applications-gsettings
             (list %app-no-gsettings %app-a %app-b)))

(test-equal "aggregation: empty application set -> empty"
            '()
            (applications-gsettings '()))

;; ── serializer ─────────────────────────────────────────────

(test-equal "serializer: schema id -> dconf path"
            "org/gnome/TextEditor"
            (gsettings-schema->dconf-path "org.gnome.TextEditor"))

(test-equal "serializer: single bool key"
            "[org/gnome/TextEditor]\nrestore-session=false\n"
            (serialize-gsettings-keyfile
             (list (make-setting "org.gnome.TextEditor"
                                 "restore-session" "false"))))

(test-equal "serializer: quoted string and uint pass through verbatim"
            "[org/a/B]\nfont-name='Sans Serif 11'\nline-height=4\n"
            (serialize-gsettings-keyfile
             (list (make-setting "org.a.B" "line-height" "4")
                   (make-setting "org.a.B" "font-name" "'Sans Serif 11'"))))

(test-equal "serializer: schema and key ordering independent of input order"
            "[org/a/A]\nk1=true\nk2=false\n[org/a/B]\nk1='x'\n"
            (serialize-gsettings-keyfile
             (list (make-setting "org.a.B" "k1" "'x'")
                   (make-setting "org.a.A" "k2" "false")
                   (make-setting "org.a.A" "k1" "true"))))

(test-assert "serializer: repeated serialization is byte-identical"
             (let ((settings
                    (list (make-setting "org.a.B" "k2" "'y'")
                          (make-setting "org.a.B" "k1" "true")
                          (make-setting "org.a.A" "k3" "[1, 2]"))))
               (string=? (serialize-gsettings-keyfile settings)
                         (serialize-gsettings-keyfile
                          (reverse settings)))))

(test-equal "serializer: empty declaration set -> empty string"
            ""
            (serialize-gsettings-keyfile '()))

;; ── session service 结构 ───────────────────────────────────

(define %home-shepherd-services
  (home-shepherd-configuration-services
   (service-value
    (fold-services (home-environment-services %guix-home)
                   #:target-type home-shepherd-service-type))))

(define %gsettings-svc
  (find (lambda (svc)
          (eq? 'gsettings-reconcile (shepherd-service-canonical-name svc)))
        %home-shepherd-services))

(test-assert "service: gsettings-reconcile present in Home Shepherd"
             (shepherd-service? %gsettings-svc))

(test-assert "service: one-shot, no respawn"
             (and (shepherd-service-one-shot? %gsettings-svc)
                  (not (shepherd-service-respawn? %gsettings-svc))))

(test-equal "service: runs after session D-Bus"
            '(dbus)
            (shepherd-service-requirement %gsettings-svc))

(define (deep-contains? pred sexp)
  "SEXP（近似 sexp，嵌套 list）中任一原子满足 PRED。"
  (cond ((pair? sexp) (or (deep-contains? pred (car sexp))
                          (deep-contains? pred (cdr sexp))))
    (else (pred sexp))))

(test-assert "service: start is program-file via make-forkexec-constructor (no shell string)"
             (let ((sexp (gexp->approximate-sexp
                          (shepherd-service-start %gsettings-svc))))
               (and (deep-contains? (lambda (x) (eq? x 'make-forkexec-constructor))
                                    sexp)
                    (not (deep-contains?
                          (lambda (x)
                            (and (string? x) (string-contains x "sh -c")))
                          sexp)))))

;; ── wrapper 源码契约（daemon 侧 lowering 硬约束）────────────
;; home derivation 在 daemon 侧 lowering 时 %load-path 没有仓库
;; modules/——wrapper 不得出现 (guixcfg …) 模块导入或 gexp 模块闭包
;; （VM 实测：闭包只剩 guix/，运行时 no code for module）。唯一
;; runtime contract 经 local-file 按值嵌入。
(test-assert "service wrapper embeds the shared runtime contract via local-file"
             (let ((s (call-with-input-file
                       "modules/guixcfg/gsettings/home-service.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "(load #$%gsettings-runtime-source)")
                    (string-contains s "(local-file \"runtime.scm\"")
                    (string-contains s "file-append")
                    (not (string-contains s "with-imported-modules"))
                    (not (string-contains s "source-module-closure")))))

(test-assert "shared runtime contract is core-guile-only (no repository module imports)"
             (let ((s (call-with-input-file
                       "modules/guixcfg/gsettings/runtime.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "open-pipe*")
                    (string-contains s "\"load\"")
                    (not (string-contains s "define-module"))
                    (not (string-contains s "#:use-module (guixcfg"))
                    (not (string-contains s "#:use-module (guix ")))))

;; ── composition 边界：generic 服务不读全局 inventory ────────
(test-assert "home-service module does not read the application registry"
             (let ((s (call-with-input-file
                       "modules/guixcfg/gsettings/home-service.scm"
                       (lambda (p) (read-string p)))))
               (and (not (string-contains s "#:use-module (guixcfg apps"))
                    (not (string-contains s "#:use-module (guixcfg users")))))

;; ── 参数化构造器 ───────────────────────────────────────────
(define %synthetic-desired
  (list (gsettings-setting (schema "org.a.B") (key "k1") (value "true"))
        (gsettings-setting (schema "org.a.B") (key "k2") (value "'x'"))))
(define %synthetic-desired-alt
  (list (gsettings-setting (schema "org.a.B") (key "k1") (value "false"))))

(define %synthetic-svc
  (gsettings-reconcile-service %synthetic-desired "/home/alice"))

(test-assert "parameterized service: one-shot, no respawn, after dbus"
             (let ((svc (car (service-value %synthetic-svc))))
               (and (shepherd-service-one-shot? svc)
                    (not (shepherd-service-respawn? svc))
                    (equal? '(dbus) (shepherd-service-requirement svc))
                    (equal? '(gsettings-reconcile)
                            (shepherd-service-provision svc)))))

;; ── build-time desired state 变化 → store identity 变化 ──────
;; 相同 desired → 相同 derivation；desired 变 → 不同（wrapper 内嵌
;; keyfile/entries，generation 重跑正是依赖这一 identity）。
;; 探针 = wrapper program-file 本身（raw start gexp 含 shepherd 自由
;; 变量 %user-log-dir，lower-object 会 invalid G-expression input）。
(define %store (open-connection))

(define (wrapper-file-name desired)
  (let ((drv (run-with-store %store
                             (lower-object
                              (gsettings-reconcile-wrapper
                               desired "/home/alice")))))
    (derivation-file-name drv)))

(test-equal "service store identity: same desired -> same derivation"
            (wrapper-file-name %synthetic-desired)
            (wrapper-file-name %synthetic-desired))

(test-assert "service store identity: different desired -> different derivation"
             (not (string=? (wrapper-file-name %synthetic-desired)
                            (wrapper-file-name %synthetic-desired-alt))))

(test-end)
