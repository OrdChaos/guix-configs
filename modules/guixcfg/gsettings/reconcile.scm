;;; GSettings reconcile（docs/architecture/gsettings.md Runtime
;;; projection）：desired declarations ↔ runtime dconf 的只读比对与
;;; 投影执行。域逻辑模块——不含 application registry、不含具体 app
;;; 设置、不含 appearance 逻辑；工具经会话 PATH 解析（不硬编码
;;; 系统路径），gsettings/dconf 缺失 → fail fast。
;;;
;;; 状态模型（status 每键五态）：
;;;   synced                 runtime == desired
;;;   drifted                runtime != desired（apply 会修）
;;;   missing-schema         schema 不存在（apply fail）
;;;   missing-key            schema 在但键不存在（apply fail）
;;;   invalid-desired-value  desired 文本过不了浅层校验（apply fail）
;;;
;;; apply 链路：validate（五态中三类失败 fail-loud）→ serialize
;;; → `dconf load /`（stdin）。只写 managed keys，绝不 reset 全库、
;;; 绝不触碰 unmanaged 状态、绝不直接生成 ~/.config/dconf/user。
;;;
;;; dry-run 契约由 Blue 命令层实现：-n 下只跑 status/plan 的只读
;;; 查询，绝不 invoke dconf load。

(define-module (guixcfg gsettings reconcile)
               #:use-module (guixcfg gsettings model)
               #:use-module (guixcfg gsettings serialize)
               #:use-module (guixcfg utils process) ; invoke-capture / invoke-with-stdin
               #:use-module (guix build utils)      ; which
               #:use-module (ice-9 match)
               #:use-module (srfi srfi-1)  ; member、filter、every
               #:use-module (srfi srfi-13) ; string-tokenize、string-trim-both、string-join
               #:export (%gsettings-actions
                         gsettings-actions
                         gsettings-validate-action-arguments
                         gsettings-status
                         gsettings-plan
                         gsettings-apply!
                         gsettings-status-format))

;;; ── action registry ────────────────────────────────────────

(define %gsettings-actions
  '(("status" . read-only)
    ("apply" . mutating)))

(define (gsettings-actions)
  "gsettings 子命令名列表（canonical 顺序）。"
  (map car %gsettings-actions))

(define (gsettings-validate-action-arguments action arguments)
  "ACTION/ARGUMENTS → canonical (action args) 或 #f（unknown action
  / 多余参数）。无 fallback。"
  (and (string? action)
       (assoc-ref %gsettings-actions action)
       (match (cons action arguments)
              (("status") '(status ()))
              (("apply") '(apply ()))
              (_ #f))))

;;; ── tooling（PATH 解析，fail fast）─────────────────────────

(define (gsettings-tool)
  (or (which "gsettings")
      (error "gsettings executable not found in PATH \
(install glib in the home profile)")))

(define (dconf-tool)
  (or (which "dconf")
      (error "dconf executable not found in PATH \
(install dconf in the home profile)")))

;;; ── runtime 查询与浅层校验 ─────────────────────────────────

(define (runtime-schema-keys schema)
  "`gsettings list-keys SCHEMA` 的键名列表；schema 不存在（非零
  退出）→ #f。"
  (false-if-exception
   (filter (negate string-null?)
           (map string-trim-both
                (string-split
                 (invoke-capture (gsettings-tool) "list-keys" schema)
                 #\newline)))))

(define (runtime-value schema key)
  "`gsettings get SCHEMA KEY` 的规范化文本；失败 → #f。"
  (false-if-exception
   (string-trim-both
    (invoke-capture (gsettings-tool) "get" schema key))))

(define (runtime-range-type schema key)
  "`gsettings range SCHEMA KEY` 的浅层类型令牌；失败 → #f。形如
  'type b'（glib 2.86 实测）——取第二个 token 做最小类型语法检查
  （b/i/u/x/d/s）；其余类型（enum/flags/tuple 等）返回 #f 表示
  '不检查'（Phase 1 不做 GVariant 类型系统，深校验由 dconf load
  接受性兜底）。"
  (false-if-exception
   (let ((tokens (string-tokenize
                  (invoke-capture (gsettings-tool) "range" schema key))))
     (and (pair? tokens)
          (string=? "type" (car tokens))
          (pair? (cdr tokens))
          (cadr tokens)))))

(define (numeric-text? s)
  (and (string->number s) #t))

(define (shallow-value-valid? value type)
  "Phase 1 最小 GVariant 文本校验：TYPE 为 #f（range 不可读或非
  简单类型）→ 不检查（接受）；'b' → true/false；'i'/'u'/'x' →
  整数文本；'d' → 数值文本；'s' → 单引号包裹的字符串文本；其余
  类型不检查。"
  (cond ((not type) #t)
    ((string=? type "b") (member value '("true" "false")))
    ((member type '("i" "u" "x")) (and (numeric-text? value)
                                       (integer? (string->number value))))
    ((string=? type "d") (numeric-text? value))
    ((string=? type "s")
     (and (>= (string-length value) 2)
          (char=? #\' (string-ref value 0))
          (char=? #\' (string-ref value (1- (string-length value))))))
    (else #t)))

;;; ── status / plan / apply ──────────────────────────────────

(define (gsettings-status settings)
  "SETTINGS → ((schema key status desired current) ...)（deterministic：
  按输入顺序；调用方用 gsettings-desired-state 提供排序输入）。"
  (map (lambda (setting)
         (let* ((schema (gsettings-setting-schema setting))
                (key (gsettings-setting-key setting))
                (desired (gsettings-setting-value setting))
                (keys (runtime-schema-keys schema)))
           (cond ((not keys)
                  (list schema key 'missing-schema desired #f))
             ((not (member key keys))
              (list schema key 'missing-key desired #f))
             ((not (shallow-value-valid?
                    desired (runtime-range-type schema key)))
              (list schema key 'invalid-desired-value desired #f))
             (else
              (let ((current (runtime-value schema key)))
                (if (not current)
                  (list schema key 'missing-key desired #f)
                  (list schema key
                        (if (string=? desired current)
                          'synced
                          'drifted)
                        desired current)))))))
       settings))

(define (gsettings-plan settings)
  "SETTINGS 中 status 非 synced 的条目（apply 的作用面）。"
  (filter (lambda (entry)
            (not (eq? 'synced (caddr entry))))
          (gsettings-status settings)))

(define (gsettings-apply! settings)
  "validate → serialize → `dconf load /`（stdin）。三类声明错误
  （missing-schema / missing-key / invalid-desired-value）fail-loud
  不 silent ignore；drifted 键由 dconf load 覆盖为 desired。
  返回 managed 键数。空声明集 → 无操作（#t，不 invoke dconf）。"
  (for-each (lambda (entry)
              (let ((status (caddr entry)))
                (unless (or (eq? status 'synced) (eq? status 'drifted))
                  (let ((schema (car entry))
                        (key (cadr entry)))
                    (error
                     (string-append "gsettings apply: " key
                                    " (" schema ") " 
                                    (case status
                                      ((missing-schema) "schema not found")
                                      ((missing-key) "key not found in schema")
                                      ((invalid-desired-value) "invalid desired value (GVariant text)")
                                      (else "unknown state")))
                     (cadddr entry))))))
            (gsettings-status settings))
  (if (null? settings)
    #t
    (begin
     (invoke-with-stdin (serialize-gsettings-keyfile settings)
                        (dconf-tool) "load" "/")
     (length settings))))

;;; ── 输出格式（Blue 命令层共享）─────────────────────────────

(define (gsettings-status-format entries)
  "ENTRIES → 逐键文本报告（schema 组 + '  key\n    desired / current
/ status'），纯格式化、无 IO。空 → 单行 'no managed keys'。"
  (if (null? entries)
    '("no managed gsettings keys (empty declaration set)")
    (let loop ((remaining entries)
               (current-schema (car (car entries)))
               (acc '()))
      (if (null? remaining)
        (reverse acc)
        (let* ((entry (car remaining))
               (schema (car entry)))
          (if (string=? schema current-schema)
            (loop (cdr remaining)
                  schema
                  (cons (string-append "  " (cadr entry)
                                       " desired: " (cadddr entry)
                                       " current: "
                                       (or (car (cddddr entry)) "<none>")
                                       " status: "
                                       (symbol->string (caddr entry)))
                        acc))
            (loop (cdr remaining)
                  schema
                  (cons (string-append "  " (cadr entry)
                                       " desired: " (cadddr entry)
                                       " current: "
                                       (or (car (cddddr entry)) "<none>")
                                       " status: "
                                       (symbol->string (caddr entry)))
                        (cons schema acc)))))))))
