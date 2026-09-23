;;; ESP LUKS UUID 文件的 activation：从 machine facts 幂等补写
;;; %esp-luks-uuid-file（(guixcfg boot layout)）。
;;;
;;; 背景：initrd derivation 不编入 LUKS UUID（offline ISO 零重建、
;;; 零下载），运行时权威身份由 ESP 上的该文件承载，initrd 解锁时经
;;; (guixcfg boot device-resolver) 的 read-luks-uuid-from-esp 读取。
;;; 写入有两个 owner 场景，本 activation 覆盖其中存量迁移：
;;;   - install：write-machine-facts（(guixcfg storage install)）直接写；
;;;   - reconfigure/boot（存量机器升级到新配置）：本 activation 从
;;;     facts 补写，保证下一次 boot 的 initrd 能读到。
;;; gexp 只嵌入常量路径（derivation 与机器 UUID 无关）；facts 在
;;; activation 运行时读取，绝不经 #$ 嵌入。

(define-module (guixcfg boot esp-uuid)
               #:use-module (gnu services)          ; simple-service
               #:use-module (gnu services base)     ; activation-service-type
               #:use-module (guix gexp)             ; with-imported-modules
               #:use-module (guix modules)          ; source-module-closure
               #:use-module (guixcfg boot layout)   ; %esp-mount-point、%esp-luks-uuid-file
               #:use-module (guixcfg system machine-facts) ; %default-machine-facts-path
               #:export (esp-luks-uuid-service))

(define (esp-luks-uuid-activation)
  ;; boot activation 可能早于 /efi 挂载（ESP 非 needed-for-boot）——
  ;; 彼时 initrd 已用过该文件，无需补写；无 facts（Live installer）
  ;; 同样跳过。reconfigure 时 /efi 已挂载、facts 存在 → 幂等补写。
  (with-imported-modules (source-module-closure
                          '((guixcfg boot device-resolver)))
    #~(begin
        (use-modules (guixcfg boot device-resolver)  ; normalize-luks-uuid
                     (ice-9 rdelim))                  ; read-line
        (let ((facts-path #$%default-machine-facts-path)
              (esp-file (string-append #$%esp-mount-point "/"
                                       #$%esp-luks-uuid-file)))
          (when (and (file-exists? facts-path)
                     (file-exists? (dirname esp-file)))
            (let* ((facts (call-with-input-file facts-path read))
                   (uuid (assq-ref facts 'luks-uuid)))
              (when uuid
                (let ((normalized
                       (or (normalize-luks-uuid uuid)
                           (error "esp-luks-uuid: invalid LUKS UUID \
in machine facts" uuid))))
                  (unless (and (file-exists? esp-file)
                               (equal? normalized
                                       (call-with-input-file esp-file
                                                             read-line)))
                    (call-with-output-file esp-file
                      (lambda (port)
                        (display normalized port)
                        (newline port)))
                    (format #t "esp-luks-uuid: wrote ~a~%" esp-file))))))))))

(define esp-luks-uuid-service
  (simple-service 'esp-luks-uuid
                  activation-service-type
                  (esp-luks-uuid-activation)))
