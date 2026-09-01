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
;;;
;;; 唯一 runtime contract：五态/浅层校验/dconf load 的实现单一事实
;;; 源是 runtime.scm（core-guile-only），本模块经 include-from-path
;;; 内联后只做 thin 包装（record↔entries 转换、PATH 工具解析、
;;; module API）——与 Home Shepherd wrapper 共享同一份实现
;;; （见 runtime.scm 头部）。

(define-module (guixcfg gsettings reconcile)
               #:use-module (guixcfg gsettings model)
               #:use-module (guixcfg gsettings serialize)
               #:use-module (guix build utils)      ; which
               #:use-module (ice-9 match)
               #:use-module (srfi srfi-1)  ; member、filter
               #:use-module (srfi srfi-13) ; string-join
               #:export (%gsettings-actions
                         gsettings-actions
                         gsettings-validate-action-arguments
                         gsettings-status
                         gsettings-plan
                         gsettings-apply!
                         gsettings-status-format))

;; 唯一 runtime contract（schema/key 校验 + 浅层值校验 + 五态 +
;; dconf load + 输出格式）：与 generated wrapper 共享的同一份源码。
(include-from-path "guixcfg/gsettings/runtime")

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

;;; ── tooling（PATH 解析，fail fast；wrapper 侧用 file-append
;;;    绝对路径，不经此处）─────────────────────────────────────

(define (gsettings-tool)
  (or (which "gsettings")
      (error "gsettings executable not found in PATH \
(install glib in the home profile)")))

(define (dconf-tool)
  (or (which "dconf")
      (error "dconf executable not found in PATH \
(install dconf in the home profile)")))

;;; ── thin 包装（record ↔ entries，委托 runtime contract）──────

(define (settings->entries settings)
  (map (lambda (setting)
         (list (gsettings-setting-schema setting)
               (gsettings-setting-key setting)
               (gsettings-setting-value setting)))
       settings))

(define (gsettings-status settings)
  "SETTINGS → ((schema key status desired current) ...)（deterministic：
按输入顺序；调用方用 gsettings-desired-state 提供排序输入）。"
  (gsettings-runtime-status (gsettings-tool) (settings->entries settings)))

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
  (for-each (lambda (problem)
              (match problem
                ((schema key text)
                 (error (string-append "gsettings apply: " key
                                       " (" schema ") " text)
                        #f))))
            (gsettings-runtime-problems (gsettings-tool)
                                        (settings->entries settings)))
  (if (null? settings)
    #t
    (begin
      (let ((status (gsettings-runtime-apply!
                     (dconf-tool)
                     (serialize-gsettings-keyfile settings))))
        (unless (zero? status)
          (error "gsettings apply: dconf load failed" status)))
      (length settings))))

(define (gsettings-status-format entries)
  "ENTRIES → 逐键文本报告行（runtime contract 的输出格式）。"
  (gsettings-runtime-format-status entries))
