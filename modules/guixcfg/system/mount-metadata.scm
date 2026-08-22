;;; GVfs 桌面 metadata 注入（docs/architecture/home.md（Trash &
;;; mount visibility））：把 HOME persistence bind mounts 的
;;; x-gvfs-hide/x-gvfs-trash 写进 /run/mount/utab。
;;;
;;; 为什么需要（GLib 2.86 / libmount / mount(2) 审计，2026-08）：
;;;   - GIO 的 mount options 来自 /proc/self/mountinfo（libmount
;;;     mnt_table_parse_mountinfo），并合并 /run/mount/utab 的
;;;     user options（mnt_table_merge_user_fs）；
;;;   - Guix 经 mount(2)（mount-file-system）挂载 bind：MS_BIND
;;;     忽略 data 参数，x-* 不进 mountinfo；GIO 的 fstab fallback
;;;     对 bind 条目不可达（mountinfo options 非 NULL）；
;;;   - 因此 /run/mount/utab 是 x-gvfs-* 对 bind mount 生效的唯一
;;;     路径。本服务在 file-systems 挂载后就位后幂等写入。
;;;
;;; 只处理"HOME persistence 桌面挂载"（options 含 x-gvfs-trash 的
;;; bind mounts）——machine-state persistence（/etc、/var 等）没有
;;; 这些 options，不注入（不是桌面用户 trash domain）。

(define-module (guixcfg system mount-metadata)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu services shepherd)   ; shepherd-service
               #:use-module (gnu system file-systems) ; file-system-*
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure、guix-module-name?
               #:use-module (guixcfg utils home-path) ; gvfs-utab-entries、ensure-gvfs-utab!
               #:use-module (srfi srfi-1)             ; filter
               #:export (gvfs-mount-metadata-service))

(define (gvfs-mount-metadata-service file-systems)
  "为 FILE-SYSTEMS 中带 x-gvfs-trash 的 bind mounts 生成 utab 条目
并注入 /run/mount/utab（one-shot shepherd 服务，requirement
file-systems）。无目标条目时返回 #f（不产生无意义服务）。"
  (let* ((mounts (filter (lambda (fs)
                           (and (memq 'bind-mount (file-system-flags fs))
                                (string=? (file-system-type fs) "none")
                                (string-contains
                                 (or (file-system-options fs) "")
                                 "x-gvfs-trash")))
                         file-systems))
         (entries (gvfs-utab-entries
                   (map (lambda (fs)
                          (cons (file-system-device fs)
                                (file-system-mount-point fs)))
                        mounts)))
         (program
          (program-file
           "gvfs-mount-metadata"
           (with-imported-modules
            (source-module-closure '((guixcfg utils home-path))
                                   #:select? (lambda (name)
                                               (or (guix-module-name? name)
                                                   (eq? (car name) 'guixcfg))))
            #~(begin
               (use-modules (guixcfg utils home-path))
               (ensure-gvfs-utab! '#$entries))))))
    (if (null? entries)
      #f
      (simple-service 'gvfs-mount-metadata shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(gvfs-mount-metadata))
                             (requirement '(file-systems))
                             (one-shot? #t)
                             (documentation
                              "Inject GVfs desktop metadata \
(x-gvfs-hide/x-gvfs-trash) for HOME persistence bind mounts into \
/run/mount/utab (GLib/libmount user options).")
                             (start #~(lambda ()
                                        (zero? (system* #$program))))
                             (stop #~(const #f))))))))
