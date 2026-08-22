;;; Generic extra-configuration-files 机制测试（(guixcfg apps
;;; extra-config)）：record 构造、校验（app 注册 / 路径合法性）、
;;; 冲突语义（同路径单 owner，fail fast）、聚合、lower 验证（安装
;;; 路径与内容保真）、Guix Home 重复路径 backstop。框架级测试
;;; （合成 fixture，不检查具体应用内容）。

(use-modules (guix store)         ; %store（合成 XDG lower）
             (guix monads)
             (guix derivations)
             (guix gexp)              ; plain-file、local-file
             (guix records)
             (gnu home)              ; home-environment
             (gnu home services)     ; home-xdg-configuration-files-service-type
             (gnu services)          ; simple-service、service-kind、service-value
             (guixcfg apps model)
             (guixcfg apps registry) ; %applications（校验权威）
             (guixcfg apps extra-config)
             (ice-9 rdelim)          ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "extra-config")

;; ── record 构造与字段 ───────────────────────────────────────
(define sample
  (extra-configuration-file
   (application 'niri)
   (path "niri/host.kdl")
   (source (plain-file "host.kdl" "debug {}\n"))))

(test-assert "extra-configuration-file constructible"
             (extra-configuration-file? sample))
(test-equal "application field" 'niri
            (extra-configuration-file-application sample))
(test-equal "path field is the full ~/.config-relative target"
            "niri/host.kdl"
            (extra-configuration-file-path sample))
(test-assert "source field is a file-like"
             (file-like? (extra-configuration-file-source sample)))

;; ── 聚合：生成 home-xdg-configuration-files 的 extension ────
(define sample-svcs
  (extra-configuration-files->home-services (list sample)))

(test-assert "aggregator returns exactly one service"
             (= 1 (length sample-svcs)))
(test-assert "service extends home-xdg-configuration-files"
             (eq? (service-extension-target
                   (car (service-type-extensions (service-kind (car sample-svcs)))))
                  home-xdg-configuration-files-service-type))
(test-assert "target path is used verbatim (no implicit prefix)"
             (equal? '(("niri/host.kdl" #t))
                     (map (lambda (entry)
                            (list (car entry) (file-like? (cadr entry))))
                          (service-value (car sample-svcs)))))

;; ── path 与 application name 解耦（不是"app 名 = 配置目录"）───
(define decoupled
  (extra-configuration-files->home-services
   (list (extra-configuration-file
          (application 'niri)          ; owner 是 niri
          (path "custom-dir/file.conf") ; 但目标路径与 app 名无关
          (source (plain-file "file.conf" "a=1\n"))))))

(test-assert "target path does not have to start with the application name"
             (equal? '(("custom-dir/file.conf" #t))
                     (map (lambda (entry)
                            (list (car entry) (file-like? (cadr entry))))
                          (service-value (car decoupled)))))

;; ── 多文件组合：不同路径全部保留 ─────────────────────────────
(define multi-files
  (list (extra-configuration-file
         (application 'niri)
         (path "niri/docked.kdl")
         (source (plain-file "docked.kdl" "docked\n")))
        (extra-configuration-file
         (application 'ghostty)
         (path "ghostty/laptop.conf")
         (source (plain-file "laptop.conf" "font-size=13\n")))))

(define multi-svcs
  (extra-configuration-files->home-services multi-files))

(test-assert "multiple different-path extras compose into one contribution"
             (let ((paths (map car (service-value (car multi-svcs)))))
               (and (member "niri/docked.kdl" paths)
                    (member "ghostty/laptop.conf" paths))))

;; ── 空列表：无贡献（无 host 配置的机器语义）──────────────────
(test-equal "empty extra list yields no services"
            '() (extra-configuration-files->home-services '()))

;; ── 校验：未知/未启用 application 立即报错（fail fast）───────
(test-assert "unknown application rejected"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services
                  (list (extra-configuration-file
                         (application 'no-such-app)
                         (path "x.kdl")
                         (source (plain-file "x.kdl" "")))))
                 #f)
               (lambda (key . args) #t)))

(test-assert "unknown application error names the app and the registry"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services
                  (list (extra-configuration-file
                         (application 'no-such-app)
                         (path "x.kdl")
                         (source (plain-file "x.kdl" "")))))
                 #f)
               (lambda (key . args)
                 (string-contains (object->string args) "no-such-app"))))

;; ── 校验：目标路径必须是应用配置目录内的合法相对路径 ─────────
(define (path-rejected? path)
  (catch #t
    (lambda ()
      (extra-configuration-files->home-services
       (list (extra-configuration-file
              (application 'niri)
              (path path)
              (source (plain-file "x" "")))))
      #f)
    (lambda (key . args) #t)))

(test-assert "absolute path rejected"
             (path-rejected? "/etc/host.kdl"))
(test-assert "parent-escape path rejected"
             (path-rejected? "../host.kdl"))
(test-assert "empty path rejected"
             (path-rejected? ""))

;; ── 校验：非 record 输入 ────────────────────────────────────
(test-assert "non-record input rejected"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services '(("niri" "x")))
                 #f)
               (lambda (key . args) #t)))

;; ── 冲突语义：同一最终 target path 只能有一个 owner ────────
(test-assert "duplicate target rejected before lowering"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services
                  (list (extra-configuration-file
                         (application 'niri)
                         (path "niri/host.kdl")
                         (source (plain-file "a.kdl" "a")))
                        (extra-configuration-file
                         (application 'niri)
                         (path "niri/host.kdl")
                         (source (plain-file "b.kdl" "b")))))
                 #f)
               (lambda (key . args) #t)))

(test-assert "duplicate error names the conflicting final path"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services
                  (list (extra-configuration-file
                         (application 'niri)
                         (path "niri/host.kdl")
                         (source (plain-file "a.kdl" "a")))
                        (extra-configuration-file
                         (application 'niri)
                         (path "niri/host.kdl")
                         (source (plain-file "b.kdl" "b")))))
                 #f)
               (lambda (key . args)
                 (string-contains (object->string args) "niri/host.kdl"))))

;; 冲突判定基于最终路径，与 owner 无关：两个不同 application
;; 贡献同一路径同样冲突（诊断里两个 owner 都在场）。
(test-assert "same final path from different owners is a conflict"
             (catch #t
               (lambda ()
                 (extra-configuration-files->home-services
                  (list (extra-configuration-file
                         (application 'niri)
                         (path "shared/x.conf")
                         (source (plain-file "a" "a")))
                        (extra-configuration-file
                         (application 'ghostty)
                         (path "shared/x.conf")
                         (source (plain-file "b" "b")))))
                 #f)
               (lambda (key . args)
                 (let ((msg (object->string args)))
                   (and (string-contains msg "shared/x.conf")
                        (string-contains msg "niri")
                        (string-contains msg "ghostty"))))))

(test-assert "different final paths never conflict"
             (let ((svcs (extra-configuration-files->home-services
                          (list (extra-configuration-file
                                 (application 'niri)
                                 (path "niri/host.kdl")
                                 (source (plain-file "a" "a")))
                                (extra-configuration-file
                                 (application 'ghostty)
                                 (path "ghostty/host.kdl")
                                 (source (plain-file "b" "b")))))))
               (let ((paths (map car (service-value (car svcs)))))
                 (and (member "niri/host.kdl" paths)
                      (member "ghostty/host.kdl" paths)))))

;; ── lower：extra 文件安装到正确 XDG 路径且内容保真 ───────────
(define (lower-home services)
  "lower + build 一个无包合成 home，返回输出目录。"
  (let* ((store (open-connection))
         (home (home-environment (packages '()) (services services)))
         (drv (run-with-store store (lower-object home))))
    (build-derivations store (list drv))
    (derivation->output-path drv)))

(define %extras-content "x=1\nsecond line\n")
(define %lowered-home
  (lower-home
   (list (car (extra-configuration-files->home-services
               (list (extra-configuration-file
                      (application 'niri)
                      (path "niri/host.kdl")
                      (source (plain-file "host.kdl" %extras-content)))
                     (extra-configuration-file
                      (application 'ghostty)
                      (path "ghostty/laptop.conf")
                      (source (plain-file "laptop.conf"
                                          "font-size=13\n")))))))))

(test-assert "extra file installed under the application's XDG config dir"
             (file-exists?
              (string-append %lowered-home
                             "/files/.config/niri/host.kdl")))
(test-assert "second extra file installed at its own path"
             (file-exists?
              (string-append %lowered-home
                             "/files/.config/ghostty/laptop.conf")))
(test-assert "extra file content preserved byte-for-byte"
             (equal? %extras-content
                     (call-with-input-file
                      (string-append %lowered-home
                                     "/files/.config/niri/host.kdl")
                      (lambda (p) (read-string p)))))

;; ── Guix Home backstop：跨贡献方（extra vs app 自身）同路径 ──
;; Guix 的 assert-no-duplicates 在 lower 时对合并后的完整文件列表
;; 查重——复用官方机制，不重复实现另一套冲突系统（任务 §七）。
;; （注意：不能在顶层定义该冲突 home——assert 在 lower 时抛错会
;; 直接让测试文件加载失败；必须包在 catch 内。）
(test-assert "cross-contributor duplicate target fails at lower time"
             (catch #t
               (lambda ()
                 (lower-home
                  (list (simple-service 'app-own-config
                                        home-xdg-configuration-files-service-type
                                        `(("niri/config.kdl"
                                           ,(plain-file "own.kdl" "own"))))
                        (car (extra-configuration-files->home-services
                              (list (extra-configuration-file
                                     (application 'niri)
                                     (path "niri/config.kdl")
                                     (source (plain-file "extra.kdl"
                                                         "extra"))))))))
                 #f)
               (lambda (key . args)
                 (or (string-contains (object->string args) "duplicate")
                     (string-contains (object->string args)
                                      "niri/config.kdl")))))

(test-end "extra-config")
