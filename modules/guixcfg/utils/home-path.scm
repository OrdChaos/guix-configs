;;; HOME consumer 中间父目录的创建与 ownership 修复原语。
;;;
;;; 语义（单一实现，被 application-persistence 与 user-persistence
;;; 两个 persistence executor 复用——它们是仅有的两个消费者；各自
;;; 的 consumer 集合可以重叠（如 .local/share 下的不同叶子），对
;;; 共同父目录重复调用本 helper 是有意且幂等的）：
;;;
;;;   HOME      用户 home 绝对路径
;;;   CONSUMER  HOME 相对路径（已由上层校验；如 ".local/share/keyrings"）
;;;   UID/GID   目标 owner
;;;
;;; 只处理 CONSUMER 的中间父目录（从浅到深逐级 mkdir-p + chown）；
;;; 不 chown HOME 本身；不处理 CONSUMER 叶子。幂等（mkdir-p 对已
;;; 存在目录是 no-op；chown 重复设置同一 owner 无害）。
;;;
;;;   例如 home=/home/user、consumer=.local/share/keyrings：
;;;     处理  /home/user/.local、/home/user/.local/share
;;;     不处理 /home/user、/home/user/.local/share/keyrings
;;;
;;; 本 helper 不实现 consumer 合法性 policy（上层已有校验；这里只做
;;; 必要的 defensive assertion，不成为第二套路径规范 authority）。
;;; 运行在 activation gexp 内（guix build utils 的 mkdir-p 可用；
;;; chown 是 Guile core）。
;;;
;;; 边界：HOME persistence mounts 的桌面集成 metadata（x-gvfs-*、
;;; mountinfo、utab）属于 (guixcfg system mount-metadata)——本模块
;;; 只做 pathname/ownership 原语。

(define-module (guixcfg utils home-path)
               #:use-module (guix build utils)   ; mkdir-p
               #:export (ensure-home-parent-directories!))

(define (ensure-home-parent-directories! home consumer uid gid)
  "确保 HOME 下 CONSUMER 的全部中间父目录存在且 owner 为 UID/GID。
从浅到深逐级 mkdir-p + chown。不 chown HOME 本身，不处理 CONSUMER
叶子。幂等。"
  ;; defensive：拒绝绝对路径（否则前导空段会把 HOME 本身 chown 掉）
  ;; 与空 consumer。consumer 的合法性 policy 由上层负责。
  (unless (and (string? consumer)
               (> (string-length consumer) 0)
               (not (string-prefix? "/" consumer)))
    (error "ensure-home-parent-directories!: invalid consumer (expected a \
non-empty HOME-relative path)"
           consumer))
  (let loop ((parts (string-split consumer #\/))
             (cur home))
    ;; parts 只剩最后一个元素（consumer 叶子）时停止——中间父目录
    ;; = consumer 除叶子外的全部前缀。
    (when (pair? (cdr parts))
      (let ((dir (string-append cur "/" (car parts))))
        (mkdir-p dir)
        (chown dir uid gid)
        (loop (cdr parts) dir)))))
