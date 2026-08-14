;;; security/tpm2/state.scm 的单元测试。由 tests/run-tests.scm 加载运行。
;;; 覆盖：enrollment metadata roundtrip、非法 metadata 拒绝、
;;; artifact 缺失/部分判定、PCR 选择固定 sha256:7、replace 原子性
;;; （.prev 回退）。

(use-modules (guixcfg security tpm2 state)
             (guix build utils)        ; delete-file-recursively
             (srfi srfi-64))

(test-begin "tpm2-state")

;; ── PCR 选择是固定事实（PCR7-only）────────────────────────
(test-equal "PCR bank 固定 sha256"
            "sha256"
            %tpm2-pcr-bank)
(test-equal "PCR list 固定 (7)"
            '("7")
            %tpm2-pcr-list)

;; ── metadata roundtrip ────────────────────────────────────
(define %sample-enrollment
  (tpm2-enrollment (id "enroll-1700000000")
                   (keyslot 2)
                   (created 1700000000)
                   (pcr7 "a1b2c3d4e5f60718293a4b5c6d7e8f901a2b3c4d5e6f708192a3b4c5d6e7f8091")
                   (notes '("recovery password keyslot 0 保留"))))

(define %tmp-file
  (string-append "/tmp/guixcfg-test-tpm2-state-"
                 (number->string (getpid)) ".scm"))

(dynamic-wind
 (const #t)
 (lambda ()
   ;; 往返
   (write-tpm2-state! %sample-enrollment %tmp-file)
   (let ((got (read-tpm2-state %tmp-file)))
     (test-equal "enrollment metadata roundtrip（id）"
                 "enroll-1700000000"
                 (tpm2-enrollment-id got))
     (test-equal "keyslot 保留"
                 2 (tpm2-enrollment-keyslot got))
     (test-equal "pcr-bank 保留"
                 "sha256" (tpm2-enrollment-pcr-bank got))
     (test-equal "pcr-list 保留"
                 '("7") (tpm2-enrollment-pcr-list got))
     (test-equal "pcr7 诊断值保留"
                 (tpm2-enrollment-pcr7 %sample-enrollment)
                 (tpm2-enrollment-pcr7 got))
     (test-equal "created 保留"
                 1700000000 (tpm2-enrollment-created got))
     (test-assert "已 enrolled"
                  (tpm2-enrolled? got)))
   
   ;; replace 原子性：覆盖旧状态；主文件损坏回退 .prev
   (let ((newer (tpm2-enrollment (id "enroll-1700000001")
                                 (keyslot 3)
                                 (created 1700000001))))
     (write-tpm2-state! newer %tmp-file)
     (test-equal "覆盖后读到新 enrollment"
                 "enroll-1700000001"
                 (tpm2-enrollment-id (read-tpm2-state %tmp-file)))
     ;; 主文件损坏（模拟断电半截）→ 回退 .prev（旧值）
     (call-with-output-file %tmp-file
                            (lambda (p) (display "((broken" p)))
     (test-equal "主文件损坏时回退 .prev"
                 "enroll-1700000000"
                 (tpm2-enrollment-id (read-tpm2-state %tmp-file))))
   
   ;; 未 enrolled：文件不存在 / 显式 #f
   (test-assert "不存在状态文件 → 未 enrolled"
                (not (tpm2-enrolled?
                      (read-tpm2-state
                       (string-append %tmp-file ".nonexistent")))))
   (write-tpm2-state! #f %tmp-file)
   (test-assert "显式写 #f → 未 enrolled"
                (not (tpm2-enrolled? (read-tpm2-state %tmp-file))))
   
   ;; ── 非法 metadata 拒绝 ────────────────────────────────────
   (let ((dir (string-append "/tmp/guixcfg-test-tpm2-bad-"
                             (number->string (getpid)))))
     (mkdir dir)
     (call-with-output-file (string-append dir "/bad.scm")
                            (lambda (p)
                              (write '((format-version . 1)
                                       (enrollment . ((id . 123)          ; id 非字符串
                                                                          (keyslot . 2)
                                                                          (created . 1))))
                                     p)
                              (newline p)))
     (test-error "id 非字符串 → 拒绝" #t
                 (read-tpm2-state (string-append dir "/bad.scm")))
     (call-with-output-file (string-append dir "/bad2.scm")
                            (lambda (p)
                              (write '((format-version . 1)
                                       (enrollment . ((id . "e")
                                                      (keyslot . "2")    ; keyslot 非整数
                                                      (created . 1))))
                                     p)
                              (newline p)))
     (test-error "keyslot 非整数 → 拒绝" #t
                 (read-tpm2-state (string-append dir "/bad2.scm")))
     (call-with-output-file (string-append dir "/bad3.scm")
                            (lambda (p)
                              (write '((format-version . 1)
                                       (enrollment . ((id . "e")
                                                      (keyslot . 2)
                                                      (pcr-bank . 7)     ; bank 非字符串
                                                      (created . 1))))
                                     p)
                              (newline p)))
     (test-error "pcr-bank 非字符串 → 拒绝" #t
                 (read-tpm2-state (string-append dir "/bad3.scm")))
     (delete-file-recursively dir))
   
   ;; ── artifact 判定（文件位于 base/objects/ 下）────────────
   (let ((dir (string-append "/tmp/guixcfg-test-tpm2-art-"
                             (number->string (getpid))))
         (obj-dir (string-append "/tmp/guixcfg-test-tpm2-art-"
                                 (number->string (getpid)) "/objects")))
     (mkdir dir)
     (mkdir obj-dir)
     (test-assert "无 artifact → 不完整"
                  (not (enrollment-artifacts-present?
                        %sample-enrollment dir)))
     (call-with-output-file (string-append obj-dir "/seal.pub")
                            (lambda (p) (display "pub" p)))
     (test-assert "只有 seal.pub → 不完整（部分 artifact）"
                  (not (enrollment-artifacts-present?
                        %sample-enrollment dir)))
     (call-with-output-file (string-append obj-dir "/seal.priv")
                            (lambda (p) (display "priv" p)))
     (test-assert "pub+priv 都在 → 完整"
                  (enrollment-artifacts-present? %sample-enrollment dir))
     (test-assert "未 enrolled 即使文件在 → 不完整"
                  (not (enrollment-artifacts-present? #f dir)))
     (delete-file-recursively dir)))
 (lambda ()
   (false-if-exception (delete-file %tmp-file))
   (false-if-exception (delete-file (string-append %tmp-file ".prev")))
   (false-if-exception (delete-file (string-append %tmp-file ".new")))))

(test-end)
