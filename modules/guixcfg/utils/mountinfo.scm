;;; mountinfo / utab 的纯 runtime 原语（无 gnu/guix 服务依赖——
;;; 供 (guixcfg system mount-metadata) 的 one-shot program 闭包，
;;; 避免把 gnu services 整棵树拖进 module-import）。
;;;
;;; 证据链（GLib 2.86 / libmount 2.42 / mount(2) 审计 + 实测）：
;;;   - GIO 的 mount options 来自 /proc/self/mountinfo（libmount
;;;     mnt_table_parse_mountinfo），并合并 /run/mount/utab 的
;;;     user options（mnt_table_merge_user_fs）；
;;;   - Guix 经 mount(2) 挂载 bind：MS_BIND 忽略 data，x-* 不进
;;;     mountinfo；GIO 的 fstab fallback 对 bind 条目不可达；
;;;   - merge_user_fs 要求 utab 条目的 SRC/TARGET/ROOT 与 mountinfo
;;;     全部匹配才合并（缺 ROOT 或 source 不匹配都会静默放弃）；
;;;   - 因此必须运行时从 /proc/self/mountinfo 提取真实 SOURCE/ROOT
;;;     （btrfs/subvolume/bind 场景下配置路径 ≠ mountinfo 值）。
;;;
;;; utab ownership（精确 marker，不做 substring 猜测）：
;;;   本服务写入的条目 OPTS 以 %guixcfg-utab-ownership-marker
;;;   （x-guixcfg.home-persistence）为 ownership token——desktop
;;;   语义（x-gvfs-hide / x-gvfs-trash）与 ownership 分离：
;;;   其它 owner 即使用相同桌面选项也必须保留；OPTS 顺序变化或
;;;   额外 options 不改变归属判定；只解析 OPTS= 字段做 token 成员
;;;   判定，绝不用整行 substring 猜 ownership。
;;;   utab 位于 /run（tmpfs）：marker 引入前的旧格式条目在下次
;;;   reboot 自然消失（无需迁移逻辑）。
;;;
;;; utab 生命周期：ensure-gvfs-utab! 按 marker 识别并替换本服务
;;; 旧行，保留其他 owner 的条目；stale TARGET 随重建消失。

(define-module (guixcfg utils mountinfo)
               #:use-module (guix build utils)        ; mkdir-p
               #:use-module (ice-9 rdelim)            ; read-string
               #:use-module (srfi srfi-1)             ; filter、find、append-map、list-index
               #:use-module (srfi srfi-13)            ; string-trim、string-split
               #:export (%gvfs-utab-path
                         %guixcfg-utab-ownership-marker
                         mangle
                         unmangle
                         parse-mountinfo
                         mountinfo-entries-for
                         gvfs-utab-entries
                         owned-entry?
                         ensure-gvfs-utab!))

;; /run/mount/utab（libmount 的 user options 文件）。parameter 化供
;; 测试覆盖（真实路径每 boot 重建）。
(define %gvfs-utab-path
  (make-parameter "/run/mount/utab"))

;; 本服务 utab 条目的 ownership marker（OPTS 字段的 token 成员）。
;; desktop 语义选项（x-gvfs-hide/x-gvfs-trash）不是 ownership 判据。
(define %guixcfg-utab-ownership-marker
  "x-guixcfg.home-persistence")

;; ── escaping（util-linux lib/mangle.c 规则）───────────────────
;; mangle：空格/\t/\n/反斜杠 → \oct（\040 \011 \012 \134）；
;; unmangle：\ + 3 个八进制位解码。utab 与 mountinfo 的路径字段都
;; 用同一规则。
(define (mangle s)
  "按 libmount mangle 规则转义 S（空格/tab/换行/反斜杠 → \\oct）。"
  (string-join
   (map (lambda (ch)
          (case ch
            ((#\space) "\\040")
            ((#\tab) "\\011")
            ((#\newline) "\\012")
            ((#\\) "\\134")
            (else (string ch))))
        (string->list s))
   ""))

(define (octal-digit? c)
  (memv c '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7)))

(define (unmangle s)
  "按 libmount mangle 规则解码 S（\\oct → 字符）。"
  (let loop ((chars (string->list s)) (acc '()))
    (cond ((null? chars) (list->string (reverse acc)))
      ((and (eq? (car chars) #\\)
            (pair? (cdr chars))
            (pair? (cddr chars))
            (pair? (cdddr chars))
            (octal-digit? (cadr chars))
            (octal-digit? (caddr chars))
            (octal-digit? (cadddr chars)))
       (loop (cddddr chars)
             (cons (integer->char
                    (+ (* 64 (- (char->integer (cadr chars))
                                (char->integer #\0)))
                       (* 8 (- (char->integer (caddr chars))
                               (char->integer #\0)))
                       (- (char->integer (cadddr chars))
                          (char->integer #\0))))
                   acc)))
      (else (loop (cdr chars) (cons (car chars) acc))))))

;; ── mountinfo 解析 ───────────────────────────────────────────
;; 行：ID PARENT MAJ:MIN ROOT MOUNTPOINT OPTIONS - FSTYPE SOURCE
;; SUPER（空格分隔；"-" 前 6 个字段，后 3 个）。
(define (parse-mountinfo text)
  "解析 /proc/self/mountinfo 文本，返回 ((mount-point source root)
...) 列表（已 unmangle）。"
  (map (lambda (line)
         (let ((fields (string-split line #\space)))
           (let ((sep (list-index (lambda (f) (string=? f "-")) fields)))
             (list (unmangle (list-ref fields 4))                 ; mount point
                   (and sep (unmangle (list-ref fields (+ sep 2)))) ; source
                   (unmangle (list-ref fields 3))))))            ; root
       (filter (lambda (l) (not (string-null? (string-trim l))))
               (string-split text #\newline))))

(define (mountinfo-entries-for mounts)
  "从 /proc/self/mountinfo 为 MOUNTS（(source target) 对列表）提取
与 libmount 解析一致的 SOURCE/ROOT，返回 (source target root) 三元
组列表——source/root 都来自 mountinfo（配置里的 bind source 路径
在 btrfs/subvolume 场景下不等于 mountinfo SOURCE/ROOT；merge_user_fs
要求与 mountinfo 一致才合并）。找不到对应挂载的条目被丢弃（挂载
尚未就位时安全）。"
  (let ((entries (parse-mountinfo
                  (call-with-input-file "/proc/self/mountinfo"
                                        (lambda (p) (read-string p))))))
    (append-map
     (lambda (m)
       (let ((target (cdr m)))
         (let ((hit (find (lambda (e) (string=? (car e) target))
                          entries)))
           (if hit
             (list (list (cadr hit) target (caddr hit)))
             '()))))
     mounts)))

;; ── utab entry 生成与更新 ────────────────────────────────────
(define (gvfs-utab-entries mounts-with-root options)
  "把 MOUNTS-WITH-ROOT（(source target root) 三元组列表）转为 utab
条目列表（SRC/TARGET/ROOT 按 libmount mangle 规则转义；OPTS=
OPTIONS + ',' + %guixcfg-utab-ownership-marker）。ROOT/SOURCE 必须
来自 mountinfo（mnt_table_merge_user_fs 要求与 mountinfo 一致才
合并）。marker 是 ownership token，与 OPTIONS 的 desktop 语义分离。"
  (map (lambda (m)
         (string-append "SRC=" (mangle (car m))
                        " TARGET=" (mangle (cadr m))
                        " ROOT=" (mangle (caddr m))
                        " OPTS=" options
                        "," %guixcfg-utab-ownership-marker))
       mounts-with-root))

(define (owned-entry? line)
  "LINE 是否本服务负责的 utab 条目：解析其 OPTS= 字段，按 ',' 切分
后做 %guixcfg-utab-ownership-marker 的 token 成员判定。只检查 OPTS
字段（SRC/TARGET/ROOT 恰好含 marker 文本不误判）；OPTS 顺序变化 /
额外 options 不影响归属；无 marker 的外来条目（即使带相同桌面
选项）不属本服务。"
  (let ((opts-field (find (lambda (field)
                           (string-prefix? "OPTS=" field))
                         (string-split line #\space))))
    (and opts-field
         (member %guixcfg-utab-ownership-marker
                 (string-split (substring opts-field
                                          (string-length "OPTS="))
                               #\,)))))

(define (ensure-gvfs-utab! entries)
  "重建 %gvfs-utab-path 中本服务负责的条目：删除旧的（marker-owned
的行），追加 ENTRIES（当前声明 + 当前 mountinfo）；其他 owner 的
条目原样保留。内容无变化时不写文件。返回本服务当前条目数
（幂等：重复调用结果一致）。"
  (let ((path (%gvfs-utab-path)))
    (mkdir-p (dirname path))
    (let* ((existing (if (file-exists? path)
                       (call-with-input-file path
                                             (lambda (p) (read-string p)))
                       ""))
           (kept (filter (lambda (line)
                           (not (owned-entry? line)))
                         (string-split existing #\newline)))
           (new-content (string-join
                         (append (filter (lambda (l)
                                           (not (string-null? (string-trim l))))
                                         kept)
                                 entries)
                         "\n")))
      (unless (string=? new-content (string-trim-right existing))
        (call-with-output-file path
                               (lambda (p)
                                 (display new-content p)
                                 (newline p))))
      (length entries))))
