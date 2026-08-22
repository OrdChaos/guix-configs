;;; seed-once 原语测试：(guixcfg utils seed-once)。
;;;
;;; 覆盖状态机三分支与幂等性：
;;;   fresh（目标不存在）      → 'seeded，内容 == seed
;;;   目标已存在（无 marker）   → 'preserved，byte-for-byte 保持
;;;   marker 已存在             → 'already-seeded，永不重复
;;;   以及 seed-once 核心语义：仓库 seed 更新不影响已初始化目标；
;;;   app 删除自身目标后不重新 seed；删除 marker 是显式重新 seed。

(use-modules (guix build utils)  ; mkdir-p、delete-file-recursively
             (ice-9 rdelim)      ; read-string
             (guixcfg utils seed-once)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "seed-once")

(define (read-text p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define (write-text p s)
  (call-with-output-file p (lambda (port) (display s port))))

(define %tmp-root
  (string-append (or (getenv "TMPDIR") "/tmp") "/guixcfg-seed-once-test"))

(define (fresh-dir name)
  (let ((d (string-append %tmp-root "/" name)))
    (mkdir-p d)
    d))

(define (cleanup!)
  (false-if-exception (delete-file-recursively %tmp-root)))

;; ── 1. fresh：目标不存在 → seed 成功 ────────────────────────
(define d1 (fresh-dir "fresh"))
(define src1 (string-append d1 "/seed.toml"))
(define dest1 (string-append d1 "/settings.toml"))
(define marker1 (string-append dest1 %seed-marker-suffix))
(write-text src1 "[shell]\nsetup_wizard_enabled = false\n")

(test-equal "fresh: returns 'seeded"
            'seeded
            (seed-once-file! dest1 src1 marker1))
(test-equal "fresh: target content equals seed content"
            "[shell]\nsetup_wizard_enabled = false\n"
            (read-text dest1))
(test-assert "fresh: marker created"
             (file-exists? marker1))

;; ── 2. marker 存在：永不重复（即使目标被 app/用户删除）──────
(test-equal "marker present: returns 'already-seeded"
            'already-seeded
            (seed-once-file! dest1 src1 marker1))
(test-equal "marker present: target untouched"
            "[shell]\nsetup_wizard_enabled = false\n"
            (read-text dest1))
(delete-file dest1)
(test-equal "marker present + target deleted: no re-seed"
            'already-seeded
            (seed-once-file! dest1 src1 marker1))
(test-assert "marker present + target deleted: target stays absent"
             (not (file-exists? dest1)))

;; ── 3. seed 更新不影响已初始化目标（seed A → 用户改 B → seed C）─
(define d2 (fresh-dir "seed-update"))
(define src2 (string-append d2 "/seed.toml"))
(define dest2 (string-append d2 "/settings.toml"))
(define marker2 (string-append dest2 %seed-marker-suffix))
(write-text src2 "A\n")
(test-equal "first seed writes A"
            'seeded
            (seed-once-file! dest2 src2 marker2))
(write-text dest2 "B\n")            ; 用户/应用随后修改
(write-text src2 "C\n")             ; 仓库 seed 更新
(test-equal "updated seed does not overwrite user data"
            'already-seeded
            (seed-once-file! dest2 src2 marker2))
(test-equal "user data preserved byte-for-byte"
            "B\n"
            (read-text dest2))

;; ── 4. 目标已存在、无 marker（备份恢复/崩溃窗口）：完全保留 ──
(define d3 (fresh-dir "preserve"))
(define src3 (string-append d3 "/seed.toml"))
(define dest3 (string-append d3 "/settings.toml"))
(define marker3 (string-append dest3 %seed-marker-suffix))
(write-text src3 "seed\n")
(write-text dest3 "restored-backup\n")
(test-equal "existing target without marker: 'preserved"
            'preserved
            (seed-once-file! dest3 src3 marker3))
(test-equal "existing target byte-for-byte preserved"
            "restored-backup\n"
            (read-text dest3))
(test-assert "preserved case: marker written"
             (file-exists? marker3))
(test-equal "preserved case: subsequent runs skip"
            'already-seeded
            (seed-once-file! dest3 src3 marker3))

;; ── 5. 删除 marker + 目标 = 显式重新 seed（维护操作）────────
(delete-file marker2)
(test-equal "marker deleted but target still present: preserved, not overwritten"
            'preserved
            (seed-once-file! dest2 src2 marker2))
(test-equal "target still present after marker deletion: untouched"
            "B\n"
            (read-text dest2))
(delete-file dest2)
(delete-file marker2)
(test-equal "marker and target both deleted: re-seed happens"
            'seeded
            (seed-once-file! dest2 src2 marker2))
(test-equal "re-seed writes current seed content"
            "C\n"
            (read-text dest2))

(cleanup!)

(test-end "seed-once")
