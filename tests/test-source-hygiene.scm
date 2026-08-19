;;; Source hygiene 测试（docs/development/applications.md、AGENT.md
;;; §12-13）：防止硬编码用户名 / HOME 绝对路径 / 开发机 checkout
;;; 路径渗入 application layer 与 generic modules。
;;;
;;; 设计原则（任务 Part K / L）：
;;;   - 只检查【明确的 contract】；不做“任何 /persist literal 都失败”
;;;     的脆弱 grep（/persist/* 是 architecture semantic path）；
;;;   - whitelist 基于架构规则，不是逐文件豁免清单；
;;;   - 测试意图：app definition 必须可移植（不知 repo root、不知
;;;     HOME 绝对路径、不知用户名）。

(use-modules (ice-9 rdelim)   ; read-string
             (ice-9 ftw)      ; scandir
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "source-hygiene")

(define (read-file p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define (scheme-files-under dir)
  "DIR 下所有 .scm 文件（递归）。"
  (let loop ((dir dir))
    (append-map (lambda (e)
                  (let ((p (string-append dir "/" e)))
                    (cond ((string-suffix? ".scm" e) (list p))
                          ((and (not (string-prefix? "." e))
                                (eq? 'directory (stat:type (stat p))))
                           (loop p))
                          (else '()))))
                (or (false-if-exception (scandir dir)) '()))))

;; ── 1. app definitions 可移植性 ─────────────────────────────
;; app definition 不得包含：
;;   - 开发机/仓库 checkout 绝对路径（getcwd/current-filename/
;;     /home/.../guix-configs 形态）
;;   - HOME 绝对路径（/home/<name>）
;;   - 用户名 literal（"user" 等作为路径/owner 出现）
;; 允许：source-relative local-file（(local-file "config.kdl")）、
;; /persist/data-app 相对 backing（不含 /persist 字面——backing 是
;; 相对路径）。
(define %app-definitions
  (filter (lambda (p) (string-suffix? "/definition.scm" p))
          (scheme-files-under "modules/guixcfg/apps")))

(test-assert "app definitions exist"
             (pair? %app-definitions))

(test-assert "app definitions contain no checkout/CWD dependence"
             (every (lambda (p)
                      (let ((s (read-file p)))
                        (and (not (string-contains s "getcwd"))
                             (not (string-contains s "current-filename")
                             )
                             (not (string-contains s "current-source-directory"))
                             (not (string-contains s "/home/")))))
                    %app-definitions))

(test-assert "app definitions do not reference the persistence root literally"
             ;; backing 是 /persist/data-app 相对路径——definition 里
             ;; 出现 "/persist/" 说明写死了绝对 backing（应只出现在
             ;; comment 的文档引用时，这里连 comment 一起禁止，保持
             ;; 严格可移植）。
             (every (lambda (p)
                      (not (string-contains (read-file p) "/persist/")))
                    %app-definitions))

;; ── 2. template 可移植性 ────────────────────────────────────
(test-assert "application template contains no username/HOME/checkout"
             (let ((s (read-file "templates/application/definition.scm")))
               (and (not (string-contains s "/home/"))
                    (not (string-contains s "getcwd"))
                    (not (string-contains s "/persist/")))))

;; ── 3. generic modules 无开发机身份 ─────────────────────────
;; 仓库代码不得出现开发者用户名 / 具体机器 checkout 绝对路径。
;; （"user"/"vm"/"laptop" 等是项目 inventory 值，不在此列。）
(test-assert "modules/ contain no developer username"
             (let ((s (string-join
                       (map read-file (scheme-files-under "modules"))
                       "\n")))
               (not (string-contains s "ordchaos"))))

(test-assert "generic modules contain no getcwd-dependent loading"
             ;; tools/ 的 add-to-load-path (getcwd) 是仓库内 CLI 的
             ;; 标准模式（运行于 checkout 内）；modules/ 禁止。
             (let ((s (string-join
                       (map read-file (scheme-files-under "modules"))
                       "\n")))
               (not (string-contains s "getcwd"))))

;; ── 4. 用户名作为路径出现在 generic 代码中 ──────────────────
;; generic executor 必须从参数取 user（task Part C：generic module
;; parameterization）——这里不扫字符串（"user" 在注释/模块名中大量
;; 合法出现），只保证 application-persistence 的 consumer 生成路径
;; 由参数化测试覆盖（tests/test-application-persistence.scm 用
;; fixture 名 alice 验证与真实用户名无关）。

(test-end "source-hygiene")
