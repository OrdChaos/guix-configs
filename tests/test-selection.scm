;;; Generic application configuration variant selection 测试
;;; （(guixcfg apps selection) + model 的 variant 声明）：
;;; variant record、selection record、校验（app 注册 / variant
;;; 声明 / target 安全）、冲突语义（同 target 单 owner，fail fast）、
;;; 解析、lower 验证（安装路径与内容保真）、Guix Home 重复路径
;;; backstop、ownership 边界（host 只做 logical selection）。
;;; 框架级测试（合成 fixture 经 #:apps 注入 + 真实 niri/laptop）。

(use-modules (guix store)         ; %store（合成 XDG lower）
             (guix monads)
             (guix derivations)
             (guix gexp)              ; plain-file、local-file
             (guix records)
             (gnu home)              ; home-environment
             (gnu home services)     ; home-files-service-type
             (gnu services)          ; simple-service、service-kind、service-value
             (guixcfg apps model)
             (guixcfg apps registry) ; %applications（校验权威）
             (guixcfg apps selection)
             (guixcfg apps niri definition)
             (guixcfg hosts laptop)
             (ice-9 rdelim)          ; read-string
             (ice-9 ftw)             ; scandir
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "selection")

;; ── variant record 构造与字段 ───────────────────────────────
(define sample-variant
  (application-configuration-variant
   (name 'laptop)
   (files `(("niri/host.kdl" ,(plain-file "host.kdl" "debug {}\n"))))))

(test-assert "application-configuration-variant constructible"
             (application-configuration-variant? sample-variant))
(test-equal "variant name field" 'laptop
            (application-configuration-variant-name sample-variant))
(test-assert "variant files is a list of (target source) entries"
             (let ((files (application-configuration-variant-files
                           sample-variant)))
               (and (= 1 (length files))
                    (string=? "niri/host.kdl" (car (car files)))
                    (file-like? (cadr (car files))))))

;; ── niri 声明：laptop variant（application-owned）────────────
(define %niri-laptop-variant
  (find (lambda (v)
          (eq? 'laptop (application-configuration-variant-name v)))
        (application-configuration-variants %niri)))

(test-assert "niri declares a laptop configuration variant"
             (application-configuration-variant? %niri-laptop-variant))
(test-assert "niri laptop variant targets niri/host.kdl (full ~/.config path)"
             (string=? "niri/host.kdl"
                       (car (car (application-configuration-variant-files
                                  %niri-laptop-variant)))))
(test-assert "niri laptop variant source is a file-like"
             (file-like? (cadr (car (application-configuration-variant-files
                                     %niri-laptop-variant)))))
(test-assert "niri laptop variant source lives in the niri application tree"
             (file-exists? "modules/guixcfg/apps/niri/variants/laptop.kdl"))

;; ── selection record：只携带 logical 字段 ────────────────────
(define sample-selection
  (application-configuration-selection
   (application 'niri)
   (variant 'laptop)))

(test-assert "selection constructible"
             (application-configuration-selection? sample-selection))
(test-equal "selection application field" 'niri
            (application-configuration-selection-application sample-selection))
(test-equal "selection variant field" 'laptop
            (application-configuration-selection-variant sample-selection))
(test-assert "selection carries no file/path fields (logical only)"
             (let ((fields (record-type-fields
                            (record-type-descriptor sample-selection))))
               (and (member 'application fields)
                    (member 'variant fields)
                    (not (member 'path fields))
                    (not (member 'source fields))
                    (not (member 'files fields)))))

;; ── laptop host 只做 logical selection ───────────────────────
(test-assert "laptop selections are logical (niri, laptop)"
             (equal? '((niri laptop))
                     (map (lambda (s)
                            (list (application-configuration-selection-application s)
                                  (application-configuration-selection-variant s)))
                          %laptop-application-configuration-selections)))
(test-assert "hosts/laptop.scm contains no target path"
             (let ((s (call-with-input-file "modules/guixcfg/hosts/laptop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "niri/host.kdl"))))
(test-assert "hosts/laptop.scm contains no source file path"
             (let ((s (call-with-input-file "modules/guixcfg/hosts/laptop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s ".kdl"))))
(test-assert "hosts/laptop.scm does not use local-file"
             (let ((s (call-with-input-file "modules/guixcfg/hosts/laptop.scm"
                                            (lambda (p) (read-string p)))))
               (not (string-contains s "local-file"))))

;; ── 解析：laptop selection → 配置文件贡献 ────────────────────
(define laptop-svcs
  (application-configuration-selections->home-services
   %laptop-application-configuration-selections))

(test-assert "laptop selection resolves to exactly one service"
             (= 1 (length laptop-svcs)))
(test-assert "resolved service extends home-files (with .config prefix)"
             (eq? (service-extension-target
                   (car (service-type-extensions (service-kind (car laptop-svcs)))))
                  home-files-service-type))
(test-assert "resolved contribution is .config/niri/host.kdl with an opaque source"
             (let ((entry (car (service-value (car laptop-svcs)))))
               (and (string=? ".config/niri/host.kdl" (car entry))
                    (file-like? (cadr entry)))))

;; ── empty selection：无贡献（VM 语义）────────────────────────
(test-equal "empty selection list yields no services"
            '() (application-configuration-selections->home-services '()))

;; ── 校验：未知 application → fail fast ───────────────────────
(test-assert "unknown application rejected"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'no-such-app)
                         (variant 'laptop))))
                 #f)
               (lambda (key . args) #t)))

(test-assert "unknown application error names the app"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'no-such-app)
                         (variant 'laptop))))
                 #f)
               (lambda (key . args)
                 (string-contains (object->string args) "no-such-app"))))

;; ── 校验：未声明 variant → fail fast（错误含 app + variant）───
(test-assert "undeclared variant rejected"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'niri)
                         (variant 'no-such-variant))))
                 #f)
               (lambda (key . args) #t)))

(test-assert "undeclared variant error names application and variant"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'niri)
                         (variant 'no-such-variant))))
                 #f)
               (lambda (key . args)
                 (let ((msg (object->string args)))
                   (and (string-contains msg "niri")
                        (string-contains msg "no-such-variant"))))))

;; ── 校验：target 必须是安全 ~/.config 相对路径（合成 apps）───
(define %synthetic-app
  (application
   (name 'synthetic)
   (configuration-variants
    (list (application-configuration-variant
           (name 'base)
           (files `(("synthetic/config.ini"
                     ,(plain-file "config.ini" "x=1\n")))))))))

(define %synthetic-app-bad
  (application
   (name 'synthetic)
   (configuration-variants
    (list (application-configuration-variant
           (name 'base)
           (files (list (list "/etc/host.conf" (plain-file "h" "")))))))))

(define %synthetic-app-escape
  (application
   (name 'synthetic)
   (configuration-variants
    (list (application-configuration-variant
           (name 'base)
           (files (list (list "../escape.conf" (plain-file "e" "")))))))))

(test-assert "absolute target path rejected"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'synthetic)
                         (variant 'base)))
                  #:apps (list %synthetic-app-bad))
                 #f)
               (lambda (key . args) #t)))

(test-assert "parent-escape target path rejected"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'synthetic)
                         (variant 'base)))
                  #:apps (list %synthetic-app-escape))
                 #f)
               (lambda (key . args) #t)))

;; ── 多文件 variant：一个 variant 贡献多个文件 ────────────────
(define %multi-file-app
  (application
   (name 'multi)
   (configuration-variants
    (list (application-configuration-variant
           (name 'dual)
           (files `(("multi/a.conf" ,(plain-file "a.conf" "a=1\n"))
                    ("multi/b.conf" ,(plain-file "b.conf" "b=2\n")))))))))

(define multi-svcs
  (application-configuration-selections->home-services
   (list (application-configuration-selection
          (application 'multi)
          (variant 'dual)))
   #:apps (list %multi-file-app)))

(test-assert "single variant may contribute multiple files"
             (let ((paths (map car (service-value (car multi-svcs)))))
               (and (member ".config/multi/a.conf" paths)
                    (member ".config/multi/b.conf" paths))))

;; ── 冲突语义：同一最终 target path 只能有一个 owner ─────────
(define %conflict-app-a
  (application
   (name 'conflict-a)
   (configuration-variants
    (list (application-configuration-variant
           (name 'v1)
           (files `(("shared/x.conf" ,(plain-file "a" "a")))))))))

(define %conflict-app-b
  (application
   (name 'conflict-b)
   (configuration-variants
    (list (application-configuration-variant
           (name 'v2)
           (files `(("shared/x.conf" ,(plain-file "b" "b")))))))))

(test-assert "duplicate target across selections rejected before lowering"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'conflict-a)
                         (variant 'v1))
                        (application-configuration-selection
                         (application 'conflict-b)
                         (variant 'v2)))
                  #:apps (list %conflict-app-a %conflict-app-b))
                 #f)
               (lambda (key . args) #t)))

(test-assert "duplicate error names the conflicting target and both sources"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'conflict-a)
                         (variant 'v1))
                        (application-configuration-selection
                         (application 'conflict-b)
                         (variant 'v2)))
                  #:apps (list %conflict-app-a %conflict-app-b))
                 #f)
               (lambda (key . args)
                 (let ((msg (object->string args)))
                   (and (string-contains msg "shared/x.conf")
                        (string-contains msg "conflict-a")
                        (string-contains msg "conflict-b"))))))

;; 同一 variant 内两个文件撞同一 target 也冲突
(define %self-conflict-app
  (application
   (name 'self-conflict)
   (configuration-variants
    (list (application-configuration-variant
           (name 'v1)
           (files `(("dup/f.conf" ,(plain-file "a" "a"))
                    ("dup/f.conf" ,(plain-file "b" "b")))))))))

(test-assert "duplicate target within one variant rejected"
             (catch #t
               (lambda ()
                 (application-configuration-selections->home-services
                  (list (application-configuration-selection
                         (application 'self-conflict)
                         (variant 'v1)))
                  #:apps (list %self-conflict-app))
                 #f)
               (lambda (key . args) #t)))

(test-assert "different targets never conflict"
             (let ((svcs (application-configuration-selections->home-services
                          (list (application-configuration-selection
                                 (application 'multi)
                                 (variant 'dual)))
                          #:apps (list %multi-file-app))))
               (let ((paths (map car (service-value (car svcs)))))
                 (and (member ".config/multi/a.conf" paths)
                      (member ".config/multi/b.conf" paths)))))

;; ── lower：variant 文件安装到正确 XDG 路径且内容保真 ─────────
(define (lower-home services)
  "lower + build 一个无包合成 home，返回输出目录。"
  (let* ((store (open-connection))
         (home (home-environment (packages '()) (services services)))
         (drv (run-with-store store (lower-object home))))
    (build-derivations store (list drv))
    (derivation->output-path drv)))

(define %laptop-kdl-content
  (call-with-input-file "modules/guixcfg/apps/niri/variants/laptop.kdl"
                        (lambda (p) (read-string p))))

(define %lowered-laptop
  (lower-home
   (application-configuration-selections->home-services
    %laptop-application-configuration-selections)))

(test-assert "laptop variant file installed under niri XDG config dir"
             (file-exists?
              (string-append %lowered-laptop
                             "/files/.config/niri/host.kdl")))
(test-assert "installed variant content matches the niri-owned source byte-for-byte"
             (equal? %laptop-kdl-content
                     (call-with-input-file
                      (string-append %lowered-laptop
                                     "/files/.config/niri/host.kdl")
                      (lambda (p) (read-string p)))))

;; ── Guix Home backstop：跨贡献方（variant vs app 自身）同路径 ──
;; Guix 的 assert-no-duplicates 在 lower 时对合并后的完整文件列表
;; 查重——复用官方机制，不重复实现另一套冲突系统。
(test-assert "cross-contributor duplicate target fails at lower time"
             (catch #t
               (lambda ()
                 (lower-home
                  (append
                   (application-configuration-selections->home-services
                    (list (application-configuration-selection
                           (application 'synthetic)
                           (variant 'base)))
                    #:apps (list %synthetic-app))
                   (list (simple-service 'app-own-config
                                         home-files-service-type
                                         `((".config/synthetic/config.ini"
                                            ,(plain-file "own.ini" "own")))))))
                 #f)
               (lambda (key . args)
                 (or (string-contains (object->string args) "duplicate")
                     (string-contains (object->string args)
                                      "synthetic/config.ini")))))

(test-end "selection")
