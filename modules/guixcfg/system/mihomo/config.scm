;;; Mihomo runtime config composition（纯逻辑，无 gnu/guix imports）：
;;; 公开模板 + subscription URL 原文 → 完整 runtime config 文本。
;;;
;;; 与 (guixcfg system mihomo service) 分离的原因：materializer program-file
;;; 经 source-module-closure 导入本模块（#:select?
;;; guixcfg-module-select?）——保持闭包最小（srfi/match only），
;;; 避免把 gnu/services 依赖拖进 generated runtime（AGENT.md §3
;;; 符号审计面）。
;;;
;;; secret 处理契约（docs/architecture/mihomo.md）：
;;;   - 允许并移除 secret 文件末尾的单个 LF 或 CRLF；
;;;   - 去除尾换行后仍含 CR、LF 或 NUL → fail closed；
;;;   - 严格 YAML 双引号转义后替换占位符；
;;;   - 占位符必须恰好出现一次，缺失/重复 → fail closed；
;;;   - 本模块绝不打印 secret（调用方负责日志）。
;;;
;;; 运行时路径契约（single-owner constants）：secret 路径必须与
;;; (guixcfg security secrets) 的 runtime-secret-target 派生一致——
;;; ordinary domain + scope system + target-name
;;; "mihomo-subscription.url"（decl 由
;;; (guixcfg system mihomo service) 的 %mihomo-secrets 声明）。

(define-module (guixcfg system mihomo config)
               #:use-module (srfi srfi-13) ; string-contains、string-suffix?、string-drop-right
               #:use-module (ice-9 string-fun) ; string-replace-substring（非 SRFI-13）
               #:use-module (ice-9 match)
               #:export (%mihomo-subscription-placeholder
                         %mihomo-secret-path
                         %mihomo-runtime-dir
                         %mihomo-runtime-config-path
                         compose-mihomo-config
                         count-substring))

(define %mihomo-subscription-placeholder "@@MIHOMO_SUBSCRIPTION_URL@@")

(define %mihomo-secret-path
  "/run/guixcfg-secrets-ordinary/system/mihomo-subscription.url")

(define %mihomo-runtime-dir "/run/mihomo")

(define %mihomo-runtime-config-path "/run/mihomo/config.yaml")

(define (count-substring s sub)
  "SUB 在 S 中出现的次数（SRFI-13 string-contains 循环；不依赖
string-count——它只数字符不数子串）。"
  (let loop ((start 0) (n 0))
    (let ((i (string-contains s sub start)))
      (if i
        (loop (+ i (string-length sub)) (+ n 1))
        n))))

(define (strip-one-trailing-newline s)
  "移除 S 末尾的【单个】LF 或 CRLF（age 解密产物常见尾换行）。
双换行只移除一个——残留换行随后被 control-char 检查 fail closed。"
  (cond
    ((string-suffix? "\r\n" s) (string-drop-right s 2))
    ((string-suffix? "\n" s) (string-drop-right s 1))
    (else s)))

(define (yaml-double-quote-escape s)
  "严格 YAML 双引号转义：反斜杠、双引号；tab 一并转义。调用方保证
输入无 CR/LF/NUL（compose 先行 fail closed）——其余字符原样保留
（URL 字符集内无其它需要转义的 C0 控制符；若未来出现再收紧）。"
  (let loop ((chars (string->list s)) (out '()))
    (match chars
           (() (list->string (reverse out)))
           ((#\\ . rest)
            (loop rest (cons* #\\ #\\ out)))
           ;; 累加顺序是倒序：输出 "\"" 需先 quote 后 backslash。
           ((#\" . rest)
            (loop rest (cons* #\" #\\ out)))
           ((#\tab . rest)
            (loop rest (cons* #\t #\\ out)))
           ((ch . rest)
            (loop rest (cons ch out))))))

(define (compose-mihomo-config template secret-raw)
  "TEMPLATE（公开模板，含恰好一次占位符）+ SECRET-RAW（subscription
URL 文件原文，可能带尾换行）→ 完整 runtime config 文本。
违反任一契约时 (throw 'mihomo-config-error MESSAGE) fail closed。
不打印、不返回值之外地暴露 secret。"
  (let ((url (strip-one-trailing-newline secret-raw)))
    (when (or (string-contains url "\r")
              (string-contains url "\n")
              (string-contains url (string #\nul)))
      (throw 'mihomo-config-error
             "subscription URL contains CR, LF or NUL after trailing-newline strip"))
    (unless (= (count-substring template %mihomo-subscription-placeholder) 1)
      (throw 'mihomo-config-error
             "template placeholder must appear exactly once"))
    (string-replace-substring template
                              %mihomo-subscription-placeholder
                              (yaml-double-quote-escape url))))
