;;; Channel 声明与锁文件的结构兼容检查（纯机制，不比较 revision 差异）。
;;;
;;; channels.scm     = tracking policy / desired channels（mutable 定义）
;;; channels.lock.scm = exact resolved revisions（额外含 commit 字段）
;;;
;;; 二者本来就不应 revision 一致；兼容性只比较结构字段：
;;;   name / url / branch / introduction（commit + 指纹）
;;; lock 侧的 commit 字段不参与比较；双向无缺失才算兼容。
;;;
;;; 实现按 s-expression 结构走读两个文件（本仓库自有的数据文件，格式
;;; 固定），不 eval、不依赖 (guix channels)——任何环境可加载
;;; （blue shell、guix repl、installer）。

(define-module (guixcfg utils channels)
               #:use-module (srfi srfi-1)
               #:use-module (srfi srfi-26)   ; cut
               #:use-module (ice-9 match)
               #:export (read-channel-declarations
                         channel-declaration-alist
                         channel-declaration-identity
                         channel-declaration-identity=?
                         channel-declaration-sets-compatible?))

(define (read-channel-declarations file)
  "读取 FILE 的首个 datum，提取全部顶层 (channel ...) 声明，各转成
((name . …) (url . …) …) alist。文件结构不合法时报错。"
  (let ((form (call-with-input-file file read)))
    (map channel-declaration-alist
         (filter (lambda (x) (and (pair? x) (eq? (car x) 'channel)))
                 form))))

(define (channel-declaration-alist decl)
  "把 (channel (name X) (url Y) ...) 转成 ((name . X) (url . Y) ...) alist。
字段值原样保留（symbol / string），不归一化类型。"
  (let loop ((fields (cdr decl)) (acc '()))
    (match fields
           (() (reverse acc))
           (((key value) . rest) (loop rest (cons (cons key value) acc)))
           (_ (error "malformed channel declaration:" decl)))))

(define (channel-introduction-identity introduction)
  "归一化 introduction：(make-channel-introduction COMMIT
(openpgp-fingerprint FP)) → (COMMIT FP)。无 introduction → #f。
指纹按 Guix 语义做空白归一化（guix describe 输出用双空格对齐，
手写声明常为单空格——同一指纹不应因排版空格被判不兼容）。"
  (match introduction
         (#f #f)
         (('make-channel-introduction commit ('openpgp-fingerprint fp))
          (list commit (string-join (string-tokenize fp) " ")))
         (_ (error "malformed channel introduction:" introduction))))

(define (channel-declaration-identity decl)
  "结构 identity：name / url / branch / introduction。commit（lock 特有）
不参与——兼容性不比较 revision。"
  (let ((get (lambda (key) (assq-ref decl key))))
    (list (get 'name) (get 'url) (get 'branch)
          (channel-introduction-identity (get 'introduction)))))

(define (channel-declaration-identity=? a b)
  (equal? (channel-declaration-identity a)
          (channel-declaration-identity b)))

(define (channel-declaration-sets-compatible? a b)
  "A 与 B 结构兼容：长度相等（重复/缺失都视为不一致），且每个 identity
双向都能在对方找到（按语义集合比较，与列表顺序无关）。"
  (and (= (length a) (length b))
       (every (lambda (x) (any (cut channel-declaration-identity=? x <>) b)) a)
       (every (lambda (x) (any (cut channel-declaration-identity=? x <>) a)) b)))
