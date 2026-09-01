;;; GSettings runtime contract —— manual（Blue/tools/gsettings.scm →
;;; reconcile.scm）与 Home Shepherd wrapper 共享的唯一 domain 实现。
;;;
;;; 消费方式（同一份源码，两种 inclusion 机制）：
;;;   - (guixcfg gsettings reconcile)：编译期
;;;     (include-from-path "guixcfg/gsettings/runtime") 内联，薄包装
;;;     导出 module API（gsettings-status / gsettings-apply! 等）；
;;;   - (guixcfg gsettings home-service) 的 generated wrapper：
;;;     (load #$(local-file "runtime.scm")) 运行时加载——home
;;;     derivation 在 daemon 侧 lowering 时 %load-path 没有仓库
;;;     modules/，wrapper 不能 import 任何仓库模块；local-file 按
;;;     值嵌入源码绕开该限制。
;;;
;;; 约束：本文件【只允许 Guile core + ice-9 绑定】（guile 自带模块
;;; 树，两种 context 都能解析）。任何 guixcfg/guix 依赖在这里出现
;;; 都会在 wrapper 运行时 no code for module。二进制路径由调用方
;;; 参数化传入（reconcile：会话 PATH 解析；wrapper：file-append
;;; 绝对 store 路径）。
;;;
;;; 契约内容（两条链语义一致）：
;;;   - schema/key 校验：gsettings list-keys（缺失 → missing-schema/
;;;     missing-key）；
;;;   - desired value 浅层校验：gsettings range 的简单类型令牌
;;;     （b/i/u/x/d/s；深校验由 dconf load 自身接受性兜底）；
;;;   - 五态 status（synced/drifted/missing-schema/missing-key/
;;;     invalid-desired-value）；
;;;   - dconf load /（stdin，唯一 mutation）；
;;;   - 错误呈现由调用方决定（wrapper：stderr + exit 1；reconcile：
;;;     error），但状态/问题分类是 domain contract、两边一致。

(use-modules (ice-9 popen)      ; open-pipe*
             (ice-9 rdelim)     ; read-string
             (ice-9 string-fun) ; string-tokenize
             (srfi srfi-1)      ; member、filter
             (srfi srfi-13))    ; string-split、string-trim-both、string-join

;;; ── 子进程原语 ────────────────────────────────────────────

(define (gsettings-runtime-capture args)
  "以 ARGV 执行子进程，返回 (values stdout 退出码)。"
  (let* ((port (apply open-pipe* OPEN_READ args))
         (out (read-string port))
         (status (close-pipe port)))
    (values out (status:exit-val status))))

;;; ── schema/key 校验 ────────────────────────────────────────

(define (gsettings-runtime-schema-keys gsettings-bin schema)
  "`gsettings list-keys SCHEMA` 的键名列表；schema 不存在（非零
退出）→ #f。"
  (call-with-values
      (lambda () (gsettings-runtime-capture
                  (list gsettings-bin "list-keys" schema)))
    (lambda (out status)
      (and (zero? status)
           (filter (negate string-null?)
                   (map string-trim-both
                        (string-split out #\newline)))))))

(define (gsettings-runtime-range-type gsettings-bin schema key)
  "`gsettings range SCHEMA KEY` 的浅层类型令牌；失败 → #f。形如
'type b'（glib 2.86 实测）——取第二个 token 做最小类型语法检查
（b/i/u/x/d/s）；其余类型（enum/flags/tuple 等）返回 #f 表示
'不检查'（Phase 1 不做 GVariant 类型系统，深校验由 dconf load
接受性兜底）。"
  (call-with-values
      (lambda () (gsettings-runtime-capture
                  (list gsettings-bin "range" schema key)))
    (lambda (out status)
      (and (zero? status)
           (let ((tokens (string-tokenize out)))
             (and (pair? tokens)
                  (string=? "type" (car tokens))
                  (pair? (cdr tokens))
                  (cadr tokens)))))))

(define (gsettings-runtime-shallow-value-valid? value type)
  "Phase 1 最小 GVariant 文本校验：TYPE 为 #f（range 不可读或非
简单类型）→ 不检查（接受）；'b' → true/false；'i'/'u'/'x' →
整数文本；'d' → 数值文本；'s' → 单引号包裹的字符串文本；其余
类型不检查。"
  (cond ((not type) #t)
        ((string=? type "b") (member value '("true" "false")))
        ((member type '("i" "u" "x"))
         (let ((n (false-if-exception (string->number value))))
           (and n (integer? n))))
        ((string=? type "d")
         (false-if-exception (and (string->number value) #t)))
        ((string=? type "s")
         (and (>= (string-length value) 2)
              (char=? #\' (string-ref value 0))
              (char=? #\' (string-ref value (1- (string-length value))))))
        (else #t)))

;;; ── 五态 status ────────────────────────────────────────────

(define (gsettings-runtime-status-entry gsettings-bin schema key desired)
  "单键状态：(schema key status desired current)。"
  (let ((keys (gsettings-runtime-schema-keys gsettings-bin schema)))
    (cond ((not keys)
           (list schema key 'missing-schema desired #f))
          ((not (member key keys))
           (list schema key 'missing-key desired #f))
          ((not (gsettings-runtime-shallow-value-valid?
                 desired (gsettings-runtime-range-type
                          gsettings-bin schema key)))
           (list schema key 'invalid-desired-value desired #f))
          (else
           (call-with-values
               (lambda () (gsettings-runtime-capture
                           (list gsettings-bin "get" schema key)))
             (lambda (out status)
               (if (not (zero? status))
                 (list schema key 'missing-key desired #f)
                 (let ((current (string-trim-both out)))
                   (list schema key
                         (if (string=? desired current)
                           'synced
                           'drifted)
                         desired current)))))))))

(define (gsettings-runtime-status gsettings-bin entries)
  "ENTRIES（((schema key desired) ...)）→ 五态条目列表（按输入
顺序）。"
  (map (lambda (entry)
         (apply gsettings-runtime-status-entry
                (cons gsettings-bin entry)))
       entries))

;;; ── 校验问题（apply 的 fail-loud 判据）────────────────────

(define (gsettings-runtime-problems gsettings-bin entries)
  "ENTRIES 中三类声明错误（missing-schema / missing-key /
invalid-desired-value）的 (schema key problem-text) 列表。"
  (filter-map
   (lambda (entry)
     (let ((status (caddr entry)))
       (and (not (or (eq? status 'synced) (eq? status 'drifted)))
            (list (car entry) (cadr entry)
                  (case status
                    ((missing-schema) "schema not found")
                    ((missing-key) "key not found in schema")
                    ((invalid-desired-value)
                     "invalid desired value (GVariant text)")
                    (else "unknown state"))))))
   (gsettings-runtime-status gsettings-bin entries)))

;;; ── dconf load（唯一 mutation）────────────────────────────

(define (gsettings-runtime-apply! dconf-bin keyfile)
  "`dconf load /`（stdin）。返回退出码（0 = 成功）。空 KEYFILE →
不执行、返回 0。"
  (if (string-null? keyfile)
    0
    (let ((port (open-pipe* OPEN_WRITE dconf-bin "load" "/")))
      (display keyfile port)
      (status:exit-val (close-pipe port)))))

;;; ── 输出格式（domain contract 的一部分）───────────────────

(define (gsettings-runtime-format-status entries)
  "五态条目列表 → 逐键文本报告行列表（schema 组 + '  key
desired/current/status'）。空 → 单行 'no managed keys'。"
  (if (null? entries)
    '("no managed gsettings keys (empty declaration set)")
    (let loop ((remaining entries)
               (current-schema (car (car entries)))
               (acc '()))
      (if (null? remaining)
        (reverse acc)
        (let* ((entry (car remaining))
               (schema (car entry))
               (line (string-append "  " (cadr entry)
                                    " desired: " (cadddr entry)
                                    " current: "
                                    (or (car (cddddr entry)) "<none>")
                                    " status: "
                                    (symbol->string (caddr entry)))))
          (if (string=? schema current-schema)
            (loop (cdr remaining) schema (cons line acc))
            (loop (cdr remaining) schema
                  (cons line (cons schema acc)))))))))
