;;; HOME persistence 共享原语（application-persistence 与
;;; user-persistence 是仅有的两个消费者——各自保证自己的
;;; prerequisites；共同部分在这里定义一次）：
;;;
;;; 1. HOME consumer 中间父目录的创建与 ownership 修复
;;;    （ensure-home-parent-directories!）；
;;; 2. HOME persistence bind mounts 的桌面集成 metadata：
;;;    x-gvfs-hide / x-gvfs-trash（GVfs/GIO 的 mount visibility 与
;;;    trash 语义——docs/architecture/home.md（Trash & mount
;;;    visibility））。
;;;
;;; x-gvfs-* 的生效路径（GLib 2.86 / libmount 审计，2026-08）：
;;;   - GIO 的 mount options 来自 /proc/self/mountinfo（libmount
;;;     mnt_table_parse_mountinfo），并合并 /run/mount/utab 的
;;;     user options（mnt_table_merge_user_fs）；
;;;   - bind mount 经 mount(2)（Guix mount-file-system）挂载：
;;;     MS_BIND 忽略 data 参数，x-* 不进 mountinfo；fstab 的
;;;     fallback（g_unix_mount_point_at）对 bind 条目不可达
;;;     （mountinfo options 非 NULL 且 GIO 忽略 fstab 的 MS_BIND
;;;     条目）；
;;;   - 因此唯一生效路径是 /run/mount/utab（libmount 合并）。
;;;     gvfs-utab-entries / ensure-gvfs-utab! 为此存在（system 层
;;;     mount-metadata 服务在 file-systems 挂载后幂等写入）。
;;;
;;; 本模块不实现 consumer 合法性 policy（上层已有校验）；不成为
;;; 第二套路径规范 authority。

(define-module (guixcfg utils home-path)
               #:use-module (guix build utils)   ; mkdir-p
               #:use-module (ice-9 rdelim)       ; read-string
               #:use-module (srfi srfi-1)        ; filter
               #:use-module (srfi srfi-13)       ; string-trim-right、string-suffix?
               #:export (ensure-home-parent-directories!
                         %persistent-home-mount-options
                         %gvfs-utab-path
                         gvfs-utab-entries
                         ensure-gvfs-utab!))

;; HOME persistence bind mounts 的桌面 metadata（GVfs 语义）：
;;   x-gvfs-hide   不作为独立挂载/卷出现在文件管理器侧边栏；
;;   x-gvfs-trash  允许对该 mount 使用 freedesktop Trash
;;                 （bind mount 被 GLib 判为 system internal，
;;                  默认 trash 被拒）。
;; machine-state persistence 不使用这些 options（/etc、/var 等不是
;; 桌面用户 trash domain）。
(define %persistent-home-mount-options
  "x-gvfs-hide,x-gvfs-trash")

;; /run/mount/utab（libmount 的 user options 文件；格式见
;; util-linux libmount/src/tab_parse.c mnt_parse_utab_line：
;; "SRC=... TARGET=... OPTS=..." 空格分隔键值对）。parameter 化供
;; 测试覆盖（真实路径每 boot 重建）。
(define %gvfs-utab-path
  (make-parameter "/run/mount/utab"))

(define (gvfs-utab-entries mounts)
  "把 MOUNTS（(source target) 对列表）转为 utab 条目列表（带
OPTS=%persistent-home-mount-options）。路径不含空格（/persist/...、
/home/...）——mangle 转义对当前路径形态无影响；含特殊字符的路径
需按 libmount mangle 规则转义（当前无此需求）。"
  (map (lambda (m)
         (string-append "SRC=" (car m) " TARGET=" (cdr m)
                        " OPTS=" %persistent-home-mount-options))
       mounts))

(define (target-of line)
  "提取 utab 行的 TARGET= 值；无 TARGET= 时返回 #f。"
  (let ((i (string-contains line "TARGET=")))
    (and i (car (string-split (substring line (+ i (string-length "TARGET=")))
                              #\space)))))

(define (ensure-gvfs-utab! entries)
  "把 ENTRIES（utab 行）幂等追加到 %gvfs-utab-path（parameter，
默认 /run/mount/utab）：已有相同 TARGET= 的行跳过；文件缺失时
创建（目录由本函数 mkdir-p）。返回追加的行数。运行在 one-shot
服务内（guix build utils 的 mkdir-p；文件操作是 Guile core）。"
  (let ((path (%gvfs-utab-path)))
    (mkdir-p (dirname path))
    (let ((existing (if (file-exists? path)
                      (call-with-input-file path
                                            (lambda (p) (read-string p)))
                      "")))
      (let ((missing
             (filter (lambda (line)
                       (let ((t (target-of line)))
                         (not (and t (string-contains existing
                                                      (string-append
                                                       "TARGET=" t))))))
                     entries)))
        (unless (null? missing)
          (call-with-output-file path
                                 (lambda (p)
                                   (display
                                    (string-append
                                     (string-trim-right existing)
                                     (if (and (not (string-null? existing))
                                              (not (string-suffix? "\n" existing)))
                                       "\n"
                                       "")
                                     (if (string-null? existing) "" "\n")
                                     (string-join missing "\n")
                                     "\n")
                                    p))))
        (length missing)))))

;;; ────────────────────────────────────────────────────────────
;;; HOME consumer 中间父目录的创建与 ownership 修复原语。

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
