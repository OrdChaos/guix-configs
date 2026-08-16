;;; Guix Home symlink-manager 的 stale pivot 保守判定与清理。
;;;
;;; 故障模型（实测复现，T6b）：Home activate 的 update-symlinks 最后两步是
;;;   (symlink new-home "~/.guix-home.new")   ; pivot
;;;   (rename-file pivot "~/.guix-home")      ; 原子切换
;;; 若 rename 失败（如 ~/.guix-home 被非空目录阻塞），pivot symlink 残留；
;;; 下一次 activate 的 (symlink new-home pivot) 直接 EEXIST 抛错，
;;; 后续 activation 永久失败（上游上游不处理 pivot 残留）。
;;;
;;; 本模块提供保守判定：只清理能明确证明是 Guix Home stale pivot 的对象
;;; （symlink 且 target 符合 store home generation 形态）；普通文件、
;;; 目录、其它 symlink 一律 fail closed。不 follow symlink，只 unlink
;;; symlink 本身。
;;;
;;; cold boot 情形：ephemeral root 下 $HOME 每次启动从零创建，上一 boot
;;; 的 pivot 残留天然消失（H6），无需额外服务——本模块服务于
;;; live reconfigure / hot activation 路径（tools/reconfigure.sh）。

(define-module (guixcfg home pivot)
               #:use-module (ice-9 regex)
               #:export (store-home-path-form?
                         store-home-path?
                         stale-pivot-disposition
                         remove-stale-pivot!))

(define (store-home-path-form? s root)
  "S 的路径形态是否为 ROOT/<hash>-home（hash 为 32 位小写 base32）。
  纯形态检查，不触碰文件系统。"
  (and (string? s)
       (string-match
        (string-append "^" (regexp-quote root) "/[0-9a-z]{32}-home$") s)
       #t))

(define* (store-home-path? s #:key (root "/gnu/store"))
         "S 是否符合真实 Guix Home generation closure 的形态：
  1. 路径形态 ROOT/<hash>-home（默认 /gnu/store）；
  2. target 实际存在（残留 pivot 指向的 generation 尚未被 GC）；
  3. target 是目录且含 Guix Home generation 的 activate 入口——
  形态近似但非真实 Home closure 的路径（如手工构造）一律拒绝。"
         (and (store-home-path-form? s root)
              (let ((st (false-if-exception (stat s))))
                (and st
                     (eq? (stat:type st) 'directory)
                     (file-exists? (string-append s "/activate"))
                     #t))))

(define* (stale-pivot-disposition path #:key (root "/gnu/store"))
         "判定 PATH（~/.guix-home.new pivot）的状态：
  absent            不存在——正常，无需处理；
  safe-stale-pivot  是指向真实 store home generation closure 的
                    symlink——可安全 unlink（Guix Home activation 失败的
                    确知残留）；
  unsafe            普通文件/目录/指向其它位置或非真实 closure 的
                    symlink——fail closed，绝不自动删除（可能是用户数据
                    或攻击者构造）。
  只用 lstat/readlink，不 follow symlink。"
         (cond
           ((not (false-if-exception (lstat path)))
            'absent)
           ((eq? (stat:type (lstat path)) 'symlink)
            (if (store-home-path? (readlink path) #:root root)
              'safe-stale-pivot
              'unsafe))
           (else 'unsafe)))

(define* (remove-stale-pivot! path #:key (root "/gnu/store"))
         "仅当 PATH 是安全可识别的 Guix Home stale pivot 时 unlink 该 symlink
本身。返回 disposition（absent/safe-stale-pivot/unsafe）。unsafe 时不动
任何文件。"
         (let ((d (stale-pivot-disposition path #:root root)))
           (when (eq? d 'safe-stale-pivot)
             (delete-file path))
           d))
