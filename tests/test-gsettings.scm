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
             (guixcfg gsettings home-service) ; %gsettings-reconcile-wrapper（core-guile 契约断言）
             (guixcfg apps model)       ; make-application、applications-gsettings
             (guixcfg apps registry)    ; %applications（唯一启用事实源）
             (guixcfg apps gnome-text-editor definition) ; %gnome-text-editor（first consumer）
             (guixcfg home user)        ; %guix-home（service 结构断言）
             (gnu home services shepherd) ; home-shepherd-service-type
             (gnu services)             ; fold-services
             (guix gexp)                ; gexp->approximate-sexp
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

(test-assert "service wrapper is core-guile only: no repository module imports"
             ;; home derivation 在 daemon 侧 lowering 时 %load-path 没有
             ;; 仓库 modules/——wrapper 里出现 (guixcfg …) 模块导入会
             ;; 在运行时 no code for module（VM 实测：source-module-closure
             ;; 闭包只剩 guix/）。源码级契约（OFF 系列同款）：wrapper
             ;; 必须 open-pipe* + dconf load（stdin），绝不允许
             ;; with-imported-modules / source-module-closure 引用仓库模块。
             (let ((s (call-with-input-file
                       "modules/guixcfg/gsettings/home-service.scm"
                       (lambda (p) (read-string p)))))
               (and (string-contains s "open-pipe*")
                    (string-contains s "\"load\"")
                    (string-contains s "file-append")
                    (not (string-contains s "with-imported-modules"))
                    (not (string-contains s "source-module-closure")))))

(test-end)
