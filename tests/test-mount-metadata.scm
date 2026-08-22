;;; GVfs mount metadata 测试（(guixcfg system mount-metadata) +
;;; (guixcfg utils home-path) 的 utab 原语）：utab 条目生成与幂等
;;; 注入、mount-metadata 服务只处理带 x-gvfs-trash 的 HOME
;;; persistence bind mounts（machine-state 不误获）、entry 格式与
;;; libmount 的 utab 契约一致（SRC/TARGET/OPTS 键值对）。

(use-modules (gnu system file-systems)
             (gnu services)
             (gnu services shepherd) ; shepherd-root-service-type、shepherd-service-*
             (guixcfg utils home-path)
             (guixcfg system mount-metadata)
             (guixcfg system user-persistence)
             (guixcfg system machine-state-persistence)
             (ice-9 rdelim)      ; read-string
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "mount-metadata")

;; ── utab 条目生成（libmount 格式）────────────────────────────
(define %sample-entries
  (gvfs-utab-entries '(("/persist/data-home/user/Documents"
                        . "/home/user/Documents")
                       ("/persist/data-app/mpv/state"
                        . "/home/user/.local/state/mpv"))))

(test-equal "utab entry format (SRC TARGET OPTS)"
            '("SRC=/persist/data-home/user/Documents TARGET=/home/user/Documents OPTS=x-gvfs-hide,x-gvfs-trash"
              "SRC=/persist/data-app/mpv/state TARGET=/home/user/.local/state/mpv OPTS=x-gvfs-hide,x-gvfs-trash")
            %sample-entries)

;; ── ensure-gvfs-utab!：幂等注入（parameter 化到 /tmp）────────
(define %utab-test-dir
  (string-append "/tmp/guixcfg-utab-" (number->string (getpid))))
(define %utab-test-path (string-append %utab-test-dir "/utab"))

(parameterize ((%gvfs-utab-path %utab-test-path))
  ;; 首次注入：全部追加
  (test-equal "first injection appends all entries"
              2 (ensure-gvfs-utab! %sample-entries))
  ;; 重复注入：幂等（已有 TARGET 跳过）
  (test-equal "re-injection is idempotent"
              0 (ensure-gvfs-utab! %sample-entries))
  ;; 内容检查：条目在场且无重复
  (let ((content (call-with-input-file %utab-test-path
                                         (lambda (p) (read-string p)))))
    (test-assert "utab content contains both entries"
                 (and (string-contains content "TARGET=/home/user/Documents")
                      (string-contains content "TARGET=/home/user/.local/state/mpv")))
    (test-assert "utab content has no duplicate TARGET"
                 (= 1 (length (filter (lambda (l)
                                        (string-contains l
                                                         "TARGET=/home/user/Documents"))
                                      (string-split content #\newline))))))
  ;; 混合：已有 + 新条目
  (test-equal "partial re-injection appends only missing"
              1 (ensure-gvfs-utab!
                 (cons "SRC=/persist/data-home/user/Pictures TARGET=/home/user/Pictures OPTS=x-gvfs-hide,x-gvfs-trash"
                       %sample-entries)))
  ;; 清理
  (false-if-exception (delete-file-recursively %utab-test-dir)))

;; ── mount-metadata 服务：只处理带 x-gvfs-trash 的 HOME bind ──
(define %user-fss (user-persistence-file-systems "user"))
(define %machine-fss
  (machine-state-persistence-file-systems
   (list (machine-state-persistence-rule
          (name 'example)
          (backing "example/state")
          (consumer "/etc/example")))))

(define %meta-svc (gvfs-mount-metadata-service %user-fss))
(define %machine-meta-svc (gvfs-mount-metadata-service %machine-fss))

(test-assert "user persistence mounts produce a metadata service"
             (and %meta-svc
                  (eq? 'gvfs-mount-metadata
                       (service-type-name (service-kind %meta-svc)))))
(test-assert "machine-state mounts produce NO metadata service"
             (not %machine-meta-svc))
(test-assert "metadata service is one-shot after file-systems"
             (let ((svc (car (service-value %meta-svc))))
               (and (eq? 'gvfs-mount-metadata
                         (car (shepherd-service-provision svc)))
                    (member 'file-systems (shepherd-service-requirement svc))
                    (shepherd-service-one-shot? svc))))

;; ── machine-state 的 file-system 无 gvfs options ─────────────
(test-assert "machine-state mounts carry no gvfs desktop options"
             (every (lambda (fs)
                      (not (string-contains (or (file-system-options fs) "")
                                            "x-gvfs-")))
                    %machine-fss))

(test-end "mount-metadata")
