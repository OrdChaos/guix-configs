;;; HOME persistence mounts 的 desktop/userspace mount metadata
;;; （GVfs/libmount 集成；docs/architecture/home.md（Trash & mount
;;; visibility））。
;;;
;;; 职责（唯一 authority）：
;;;   - %persistent-home-mount-options：data-home/data-app bind mounts
;;;     的桌面 options 共享常量（file-system options 与 utab OPTS
;;;     同源）；
;;;   - Shepherd one-shot 服务：file-systems 挂载后，运行时经
;;;     (guixcfg utils mountinfo) 从 /proc/self/mountinfo 提取
;;;     SOURCE/ROOT，重建 /run/mount/utab 中本服务条目。
;;;
;;; 证据链（GLib 2.86 / libmount 2.40 / mount(2) 审计 + 实测，2026-08）：
;;;   - GIO 的 mount options 来自 mountinfo（libmount 解析），合并
;;;     utab user options（mnt_table_merge_user_fs）；
;;;   - Guix 经 mount(2) 挂载 bind：x-* 不进 mountinfo；fstab
;;;     fallback 对 bind 不可达；
;;;   - merge_user_fs 要求 SRC/TARGET/ROOT 与 mountinfo 一致才合并；
;;;   - 因此运行时从 mountinfo 提取 SOURCE/ROOT 写 utab（机制在
;;;     (guixcfg utils mountinfo)，本模块不直接承载——避免把
;;;     gnu services 整棵树拖进 program module-import）。
;;;
;;; machine-state persistence 不使用本模块的 options（/etc、/var 等
;;; 不是桌面用户 trash domain）。

(define-module (guixcfg system mount-metadata)
               #:use-module (gnu services)            ; simple-service
               #:use-module (gnu services shepherd)   ; shepherd-service
               #:use-module (gnu system file-systems) ; file-system-*
               #:use-module (guix gexp)
               #:use-module (guix modules)            ; source-module-closure、guix-module-name?
               #:use-module (guixcfg utils mountinfo) ; 运行时原语（program 闭包）
               #:use-module (srfi srfi-1)             ; filter
               #:export (%persistent-home-mount-options
                         gvfs-mount-metadata-service))

;; HOME persistence bind mounts 的桌面 metadata（GVfs 语义）：
;;   x-gvfs-hide   不作为独立挂载/卷出现在文件管理器侧边栏；
;;   x-gvfs-trash  允许该 mount 使用 freedesktop Trash（bind mount
;;                 默认被 GLib 判为 system internal，trash 被拒）。
;; machine-state persistence 不使用（见模块头）。
(define %persistent-home-mount-options
  "x-gvfs-hide,x-gvfs-trash")

;; ── Shepherd one-shot 服务 ───────────────────────────────────
(define (gvfs-mount-metadata-service file-systems)
  "为 FILE-SYSTEMS 中带 x-gvfs-trash 的 bind mounts 生成 utab 条目
并注入 /run/mount/utab（one-shot shepherd 服务，requirement
file-systems——挂载后就位，运行时从 mountinfo 读 SOURCE/ROOT；
按 TARGET 重建本服务条目，保留其他 owner）。无目标条目时返回 #f
（不产生无意义服务）。"
  (let* ((mounts (filter (lambda (fs)
                           (and (memq 'bind-mount (file-system-flags fs))
                                (string=? (file-system-type fs) "none")
                                (string-contains
                                 (or (file-system-options fs) "")
                                 "x-gvfs-trash")))
                         file-systems))
         (mount-pairs (map (lambda (fs)
                             (cons (file-system-device fs)
                                   (file-system-mount-point fs)))
                           mounts))
         (program
          (program-file
           "gvfs-mount-metadata"
           (with-imported-modules
            ;; 只闭包纯 runtime 模块（+ guix build utils）——闭包
            ;; 本模块会把 gnu services 整棵树拖进 module-import
            ;; （实测：rust-crates patch 缺失构建失败）。
            (source-module-closure '((guix build utils)
                                     (guixcfg utils mountinfo))
                                   #:select? (lambda (name)
                                               (or (guix-module-name? name)
                                                   (eq? (car name) 'guixcfg))))
            #~(begin
               (use-modules (guix build utils)
                            (guixcfg utils mountinfo))
               ;; 运行时从 /proc/self/mountinfo 提取 SOURCE/ROOT
               ;; （merge_user_fs 要求与 mountinfo 一致），构造带
               ;; ROOT 的 utab 行后按 TARGET 重建本服务条目。
               (ensure-gvfs-utab!
                (gvfs-utab-entries (mountinfo-entries-for '#$mount-pairs)
                                   #$%persistent-home-mount-options)
                #$%persistent-home-mount-options))))))
    (if (null? mount-pairs)
      #f
      (simple-service 'gvfs-mount-metadata shepherd-root-service-type
                      (list (shepherd-service
                             (provision '(gvfs-mount-metadata))
                             (requirement '(file-systems))
                             (one-shot? #t)
                             (documentation
                              "Inject GVfs desktop metadata \
(x-gvfs-hide/x-gvfs-trash) for HOME persistence bind mounts into \
/run/mount/utab (GLib/libmount user options; SOURCE/ROOT read from \
mountinfo at runtime; rebuilds service-owned entries only).")
                             (start #~(lambda ()
                                        (zero? (system* #$program))))
                             (stop #~(const #f))))))))
