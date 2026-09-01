;;; 机器事实（machine facts）路径解析与读取机制。
;;;
;;; 从 (guixcfg system file-systems) 提取出的纯机制层：facts 文件是
;;; 安装器写入、可重新探测的机器事实（docs/architecture/storage.md
;;; （固定命名事实）），不进 Git。构建期读取，路径解析规则：
;;;   1. GUIX_CONFIG_FACTS（非空）→ 显式 override，必须存在且格式合法，
;;;      否则立即报错——显式指定不允许静默忽略；
;;;   2. 否则 /persist/system/facts/host.scm 存在 → 自动使用（已安装系统
;;;      reconfigure 无需环境变量）；
;;;   3. 否则 → 无 machine facts（boot-critical fact 缺失时在构造
;;;      mapped-device 处 fail-closed，不回退 by-partlabel）。
;;;
;;; 提取动机：file-systems 模块顶层 import virelith/nonguix 等 channel
;;; 模块，blue 的 shell 环境（development manifest）没有这些 channel 的
;;; module 树；doctor 需要在不加载完整 OS 的前提下复用同一套 resolution
;;; policy——单一事实源，禁止复制第二套 resolver。
;;;
;;; 本模块保持 channel-free：只依赖 (guixcfg storage model) 的
;;; persist-mount-point（固定事实）与 Guile core。

(define-module (guixcfg system machine-facts)
               #:use-module (guixcfg storage model)  ; persist-mount-point（固定事实）
               #:use-module (srfi srfi-1)            ; every
               #:export (%default-machine-facts-path
                         machine-facts-path
                         resolve-facts-path
                         load-machine-facts
                         facts-alist?
                         machine-facts
                         machine-fact
                         require-fact
                         require-machine-fact))

(define %default-machine-facts-path
  (string-append (persist-mount-point "@persist-system") "/facts/host.scm"))

(define (regular-file? path)
  "PATH 存在且是普通文件（目录等显式拒绝）。"
  (and (file-exists? path)
       (eq? (stat:type (stat path)) 'regular)))

(define (resolve-facts-path override default)
  "解析 facts 路径（纯函数，便于测试）。OVERRIDE 是 GUIX_CONFIG_FACTS
的值（#f 或空串 = 未设置）。返回实际路径或 #f（无 facts）。"
  (cond
    ((and override (not (string-null? override)))
     (cond
       ((regular-file? override) override)
       ((file-exists? override)
        (error "GUIX_CONFIG_FACTS does not point to a regular file:" override))
       (else
        (error "GUIX_CONFIG_FACTS points to a missing file:" override))))
    ((regular-file? default) default)
    ((file-exists? default)
     (error "default machine facts path is not a regular file:" default))
    (else #f)))

(define (machine-facts-path)
  (resolve-facts-path (getenv "GUIX_CONFIG_FACTS") %default-machine-facts-path))

(define (facts-alist? x)
  (and (list? x) (every pair? x)))

(define (load-machine-facts path)
  "读取并校验 facts 文件：必须是可 read 的 alist，否则显式报错。"
  (let ((facts (catch #t
                 (lambda ()
                   (call-with-input-file path read))
                 (lambda (key . args)
                   (error "cannot parse machine facts file:" path key args)))))
    (unless (facts-alist? facts)
      (error "malformed machine facts file (expected an alist):" path))
    facts))

;; 惰性求值：模块加载阶段不执行任何 I/O 或校验——guile 的
;; resolve-module 会吞掉模块加载失败时的原始错误并留下半成品模块，
;; 依赖方（hosts/vm.scm）只会看到 unbound variable。所有 facts 读取
;; 与校验推迟到首次 force 时，届时错误在调用方求值路径上抛出，
;; 信息清晰可诊断。
(define %machine-facts
  (delay (let ((path (machine-facts-path)))
           (if path (load-machine-facts path) '()))))

(define (machine-facts)
  (force %machine-facts))

(define (machine-fact key)
  (assq-ref (machine-facts) key))

(define (require-fact facts key)
  "FACTS 中必须存在 KEY；缺失立即报错（fail-closed）——宁可
reconfigure 失败，也不生成已知 initrd 无法解锁的配置。"
  (or (assq-ref facts key)
      (error "missing required machine fact:" key
             "refusing to build a bootable system")))

(define (require-machine-fact key)
  (require-fact (machine-facts) key))
