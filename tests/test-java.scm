;;; Java application unit 测试（Level 3：generated artifact 真实执行，
;;; docs/development/testing.md）。
;;;
;;; 覆盖：
;;;   J1 版本表：major 恰为 8/17/21/24、包互不相同、默认版本在表内
;;;   J2 profile 贡献：只装默认版本的 "jdk" output（第二个 JDK 进
;;;      profile 会同名 output 冲突/静默 first-wins——见 definition
;;;      文件头）
;;;   J3 wrapper 目标：每个 major 一个 ~/.local/bin/javaN 贡献
;;;   J4 wrapper 真实执行：javaN -version 输出的 major 与声明一致
;;;      （证明 wrapper → 对应 store JDK 的映射，而不是"看起来像"）
;;;   J5 JAVA_HOME：build 期值（非运行时探测），且等于默认 JDK 的
;;;      "jdk" output；$JAVA_HOME/bin/java 的 major = 默认版本
;;;   J6 GC 存活前提（store reference 语义，definition 文件头）：每个
;;;      wrapper 的 references 必须含该版本的 launcher output（否则
;;;      guix gc 后 wrapper 里的路径悬空）；profile 的 references
;;;      必须含 JAVA_HOME 指向的 "jdk" output
;;;
;;; JDK store output 不在本地 store 时（离线且无 substitute）跳过
;;; J4/J5 的执行级断言——测试不依赖公网可用性（AGENT.md §4）。

(use-modules (guixcfg apps java definition)
             (guixcfg apps model)
             (gnu home services)      ; home-files / home-environment-variables
             (gnu services)           ; service-extension-target
             (guix store)             ; open-connection、valid-path?、build-derivations
             (guix monads)            ; run-with-store
             (guix packages)          ; package-derivation
             (guix profiles)          ; profile-derivation
             (guix derivations)       ; derivation->output-path
             (guix gexp)              ; gexp?、file-like?、program-file、lower-object
             (ice-9 rdelim)           ; read-line
             (ice-9 regex)            ; string-match、match:substring
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "java")

(define %store (open-connection))

;; simple-service 生成匿名 service-type（kind name = service 名），
;; 因此按 extension target 识别贡献类别（test-gnupg 同款）。
(define (app-contribution-values app target-type)
  (filter-map (lambda (svc)
                (and (any (lambda (ext)
                            (eq? target-type (service-extension-target ext)))
                          (service-type-extensions (service-kind svc)))
                     (service-value svc)))
              (application-home-services app)))

;; home-files / home-environment-variables 的贡献值都是 alist →
;; 展平成一个 alist（同 target 不会被两个 app 声明）。
(define (app-alist-contributions app target-type)
  (apply append (app-contribution-values app target-type)))

(define %java-files (app-alist-contributions %java home-files-service-type))

;; home-files 条目是 2 元素 list → 取 source 用 cadr（不是 assoc-ref 的
;; cdr，那只对 env vars 的 pair 成立）。
(define (home-file-source target)
  (let ((entry (assoc target %java-files)))
    (and entry (cadr entry))))
(define %java-env (app-alist-contributions %java
                                           home-environment-variables-service-type))

(define (jdk-output-store-path jdk output)
  "JDK 包 OUTPUT 的 store 路径（客户端计算；#:graft? #f 避免
testing.md 记录的 package-derivation graft 陷阱）。"
  (derivation->output-path (package-derivation %store jdk #:graft? #f)
                           output))

(define (jdk-store-path jdk)
  "默认 JDK 的 \"jdk\" output（完整 JDK image）store 路径。"
  (jdk-output-store-path jdk "jdk"))

(define (jdk-launcher-store-path jdk)
  "JDK 包默认 output（JRE image）store 路径——wrapper 指向它。"
  (jdk-output-store-path jdk "out"))

(define (store-references path)
  (let ((info (query-path-info %store path)))
    (and info (path-info-references info))))

(define (build thing)
  (let ((drv (run-with-store %store (lower-object thing))))
    (build-derivations %store (list drv))
    (derivation->output-path drv)))

(define (capture-run program args)
  "运行 PROGRAM ARGS，返回 (stdout . stderr) 文本（无 shell——
Java 的 -version 走 stderr，故两个流都收）。"
  (let ((out-file (string-append "/tmp/guixcfg-java-test-out-"
                                 (number->string (getpid))))
        (err-file (string-append "/tmp/guixcfg-java-test-err-"
                                 (number->string (getpid)))))
    (define (slurp file)
      (dynamic-wind
       (lambda () #f)
       (lambda ()
         (if (file-exists? file)
           (call-with-input-file file
             (lambda (port)
               (let loop ((lines '()))
                 (let ((line (read-line port)))
                   (if (eof-object? line)
                     (apply string-append (reverse lines))
                     (loop (cons (string-append line "\n") lines)))))))
           ""))
       (lambda () (false-if-exception (delete-file file)))))
    (with-output-to-file out-file
      (lambda ()
        (with-error-to-file err-file
          (lambda () (apply system* program args)))))
    (cons (slurp out-file) (slurp err-file))))

(define (java-major text)
  "从 `java -version` 文本取 major：1.8.0_292 → 8；21.0.2 → 21。"
  (let ((m (string-match "version \"([0-9]+)\\.?([0-9]+)?" text)))
    (and m
         (let ((first (match:substring m 1))
               (second (match:substring m 2)))
           (if (string=? first "1")
             (string->number second)
             (string->number first))))))

;; ── J1：版本事实表 ─────────────────────────────────────────
(test-equal "J1: version table majors are exactly 8/17/21/24"
            '(8 17 21 24)
            (map car %java-version-table))

(test-assert "J1: default java is one of the declared versions"
             (memq %default-java (map cdr %java-version-table)))

(test-assert "J1: each major maps to a distinct package"
             (let ((pkgs (map cdr %java-version-table)))
               (= (length pkgs) (length (delete-duplicates pkgs eq?)))))

;; ── J2：profile 只承载默认版本的 "jdk" output ───────────────
(test-assert "J2: profile contributes exactly the default JDK's jdk output"
             (let ((packages (application-home-packages %java)))
               (and (= 1 (length packages))
                    (let ((entry (car packages)))
                      (and (list? entry)
                           (= 2 (length entry))
                           (eq? %default-java (car entry))
                           (string=? "jdk" (cadr entry)))))))

;; ── J3：每版本的稳定访问名 ────────────────────────────────
;; 期望值是字面量（string<? 是字典序：java17 < java21 < java24 < java8）。
(test-equal "J3: one ~/.local/bin/javaN wrapper per declared version"
            '(".local/bin/java17" ".local/bin/java21"
              ".local/bin/java24" ".local/bin/java8")
            (sort (map car %java-files) string<?))

;; Home 契约：home-files 条目必须是 **(target source) 两元素 list**
;; （dotted pair 会让 symlink-manager 的 match 失败——不是 env vars 的
;; pair 形态）。
(test-assert "J3: home-files entries are 2-element (target source) lists"
             (every (lambda (entry)
                      (and (list? entry)
                           (= 2 (length entry))
                           (string? (car entry))
                           (or (gexp? (cadr entry))
                               (file-like? (cadr entry)))))
                    %java-files))

;; ── J5（结构）：JAVA_HOME 是 build 期值，不是运行时探测 ─────
(test-assert "J5: JAVA_HOME is a build-time value (gexp/file-like), not a runtime probe"
             (let ((value (assoc-ref %java-env "JAVA_HOME")))
               (and value (or (gexp? value) (file-like? value)))))

;; ── J4/J5（执行）：JDK 在本地 store 时真实运行 ──────────────
(define (jdk-available? jdk)
  (valid-path? %store (jdk-store-path jdk)))

(define %jdks-available?
  (every jdk-available? (map cdr %java-version-table)))

(if %jdks-available?
  (begin
    ;; J4：每个 wrapper 真实执行 → major 与声明一致。
    (for-each
     (lambda (entry)
       (let* ((major (car entry))
              (target (string-append ".local/bin/java"
                                     (number->string major)))
              (program (build (home-file-source target)))
              (version-text (cdr (capture-run program '("-version")))))
         (test-equal (string-append "J4: " target
                                    " reports its declared major version")
                     major
                     (java-major version-text))))
     %java-version-table)

    ;; J5：JAVA_HOME == 默认 JDK 的 "jdk" output，且其 bin/java 的
    ;; major = 默认版本（profile 的 java 与 JAVA_HOME 同一目录）。
    (let* ((value (assoc-ref %java-env "JAVA_HOME"))
           (home (string-trim-right
                  (car (capture-run
                        (build (program-file
                                "java-home-value-probe"
                                #~(begin (display #$value) (newline))))
                        '()))
                  #\newline)))
      (test-equal "J5: JAVA_HOME equals the default JDK's jdk output path"
                  (jdk-store-path %default-java)
                  home)
      (test-equal "J5: $JAVA_HOME/bin/java reports the default major version"
                  (car (find (lambda (entry)
                               (eq? %default-java (cdr entry)))
                             %java-version-table))
                  (java-major
                   (cdr (capture-run (string-append home "/bin/java")
                                     '("-version"))))))

    ;; J6：GC 存活前提（见 definition 文件头 store reference 一节）。
    (for-each
     (lambda (entry)
       (let* ((major (car entry))
              (jdk (cdr entry))
              (target (string-append ".local/bin/java"
                                     (number->string major)))
              (wrapper (build (home-file-source target))))
         (test-assert (string-append "J6: " target
                                     " wrapper references its launcher output")
                      (let ((refs (store-references wrapper)))
                        (and refs
                             (member (jdk-launcher-store-path jdk) refs))))))
     %java-version-table)

    ;; #:hooks '()：这里只断言 manifest→profile 的 store reference
    ;; 语义，profile hooks（font/desktop cache 等）与断言无关，且会
    ;; 引入额外依赖（保持测试离线可用）。
    (let* ((profile (run-with-store
                     %store
                     (profile-derivation
                      (packages->manifest (application-home-packages %java))
                      #:hooks '()))))
      (build-derivations %store (list profile))
      (test-assert "J6: profile references the JDK output JAVA_HOME points at"
                   (let ((refs (store-references
                                (derivation->output-path profile))))
                     (and refs
                          (member (jdk-store-path %default-java) refs))))))
  (display "NOTE: JDK store outputs unavailable locally; J4/J5/J6 execution assertions skipped\n"))
