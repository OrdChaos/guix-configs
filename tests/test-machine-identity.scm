;;; Machine identity（/etc/machine-id）持久化测试：
;;; modules/guixcfg/system/machine-identity.scm。
;;;
;;; 覆盖：
;;;   A. 格式校验（32 hex；dbus machine-id 契约）；
;;;   B. 首次初始化：persistent canonical 缺失 → 生成一次 → 原子写入
;;;      → 投影 /etc/machine-id，两者一致；
;;;   C. 第二次启动回归：ephemeral root 重建（/etc/machine-id 消失）、
;;;      canonical 保留 → restore → /etc/machine-id == 上次 ID；
;;;   D. 幂等：重复 activation 结果不变；
;;;   E. 防覆盖：canonical 已存在 → 生成器绝不再次调用、内容绝不变；
;;;   F. /etc/machine-id 损坏/空/缺失 → 投影自愈为 canonical
;;;      （空/损坏的 /etc/machine-id 会让 pinned dbus activation 的
;;;      dbus-uuidgen --ensure 直接失败——INVALID_FILE_CONTENT）；
;;;   G. canonical 损坏 → fail closed（不重新生成、不覆盖）；
;;;   H. dbus-uuidgen 包装：正常/失败/非法输出；
;;;   I. host 接线时序：%vm-os / %laptop-os 的 activation 里，
;;;      machine-id restore 必须先于 D-Bus activation 的
;;;      dbus-uuidgen --ensure=/etc/machine-id。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (gnu system)            ; operating-system-services
             (gnu services)
             (guix gexp)             ; gexps->script、gexp->approximate-sexp
             (guix build utils)      ; mkdir-p、delete-file-recursively
             (ice-9 rdelim)          ; read-string
             (srfi srfi-1)           ; list-index
             (guixcfg utils machine-id)
             (guixcfg system machine-identity)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "machine-identity")

(define %tmp-root
  (string-append (or (getenv "TMPDIR") "/tmp") "/guixcfg-machine-id-test"))

(define (read-text p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define (fresh-dir name)
  (let ((d (string-append %tmp-root "/" name)))
    (mkdir-p d)
    d))

(define (cleanup!)
  (false-if-exception (delete-file-recursively %tmp-root)))

;; 开头清理残留（上次失败运行可能留下临时目录，污染“缺失”断言）。
(cleanup!)

;; 固定的合法 machine-id（32 hex）。
(define %sample-id "a90fbfd877b80658dabf8e326a940c6a")

;; fake dbus-uuidgen：打印 CONTENT（exit 0）或失败。
(define (write-fake-uuidgen dir name content exit-code)
  (let ((p (string-append dir "/" name)))
    (call-with-output-file p
                          (lambda (port)
                            (format port "#!/bin/sh~%echo \"~a\"~%exit ~a~%"
                                    content exit-code)))
    (chmod p #o755)
    p))

;; ── A. 格式校验 ──────────────────────────────────────────────
(test-assert "valid: 32 hex"
             (machine-id-valid? %sample-id))
(test-assert "valid: with trailing newline"
             (machine-id-valid? (string-append %sample-id "\n")))
(test-assert "valid: with surrounding whitespace"
             (machine-id-valid? (string-append "  " %sample-id " \t\n")))
(test-assert "valid: uppercase hex"
             (machine-id-valid? (string-upcase %sample-id)))
(test-assert "invalid: too short"
             (not (machine-id-valid? (substring %sample-id 0 31))))
(test-assert "invalid: too long"
             (not (machine-id-valid? (string-append %sample-id "0"))))
(test-assert "invalid: empty"
             (not (machine-id-valid? "")))
(test-assert "invalid: whitespace only"
             (not (machine-id-valid? "  \n\t")))
(test-assert "invalid: non-hex"
             (not (machine-id-valid? (string-append "z" (substring %sample-id 1)))))
(test-assert "invalid: not a uuid-with-dashes format"
             (not (machine-id-valid?
                   "a90fbfd8-77b80658-dabf8e32-6a940c6a")))
(test-equal "normalize: trims and returns content"
            %sample-id
            (normalize-machine-id (string-append %sample-id "\n")))
(test-equal "normalize: invalid -> #f"
            #f
            (normalize-machine-id "junk"))

;; ── B. 首次初始化（persistent canonical 不存在）──────────────
(define boot1 (fresh-dir "first-boot"))
(define canonical1 (string-append boot1 "/persist/machine-id"))
(define etc1 (string-append boot1 "/etc/machine-id"))
(define fake1 (write-fake-uuidgen boot1 "uuidgen" %sample-id 0))

(test-equal "first init: read-machine-id-file on missing -> #f"
            #f
            (read-machine-id-file canonical1))
(test-assert "first init: ensure generates canonical"
             (string=? %sample-id
                       (ensure-machine-id! canonical1
                                           (lambda () (generate-machine-id fake1)))))
(test-equal "first init: canonical file content"
            (string-append %sample-id "\n")
            (read-text canonical1))
(test-equal "first init: canonical mode 0444"
            #o444
            (stat:perms (stat canonical1)))
(test-equal "first init: project /etc/machine-id"
            %sample-id
            (project-machine-id! canonical1 etc1))
(test-equal "first init: /etc/machine-id content matches canonical"
            (string-append %sample-id "\n")
            (read-text etc1))
(test-equal "first init: /etc/machine-id mode 0444"
            #o444
            (stat:perms (stat etc1)))

;; ── C. 第二次启动回归（ephemeral root 重建）──────────────────
;; 模拟 reboot：/etc 整个消失（新 root generation），persistent
;; canonical 保留 → 必须恢复同一个 ID。
(define boot2 (fresh-dir "second-boot"))
(define canonical2 (string-append boot2 "/persist/machine-id"))
(define etc2 (string-append boot2 "/etc/machine-id"))
(define fake2 (write-fake-uuidgen boot2 "uuidgen" %sample-id 0))

;; 第一次 boot（install/init）：
(test-assert "boot1: mint identity"
             (string=? %sample-id
                       (ensure-machine-id! canonical2
                                           (lambda () (generate-machine-id fake2)))))
(project-machine-id! canonical2 etc2)
;; reboot：root 重建，/etc/machine-id 消失，canonical 保留：
(delete-file-recursively (dirname etc2))
(test-assert "reboot: /etc/machine-id gone"
             (not (file-exists? etc2)))
(test-assert "reboot: persistent canonical retained"
             (file-exists? canonical2))
;; 第二次 boot：
(test-assert "boot2: restore same identity (no regeneration)"
             (string=? %sample-id
                       (ensure-machine-id! canonical2
                                           (lambda () (generate-machine-id fake2)))))
(test-equal "boot2: /etc/machine-id == previous ID"
            (string-append %sample-id "\n")
            (begin (project-machine-id! canonical2 etc2)
                   (read-text etc2)))
(test-equal "boot2: canonical unchanged after restore"
            (string-append %sample-id "\n")
            (read-text canonical2))

;; ── D. 幂等：重复执行结果不变 ───────────────────────────────
(test-assert "idempotent: repeated ensure returns same id"
             (every (lambda (_)
                      (string=? %sample-id
                                (ensure-machine-id! canonical2
                                                    (lambda () (generate-machine-id fake2)))))
                    (iota 3)))
(test-equal "idempotent: repeated projection leaves content unchanged"
            (string-append %sample-id "\n")
            (begin (project-machine-id! canonical2 etc2)
                   (read-text etc2)))

;; ── E. 防覆盖：canonical 已存在 → 生成器绝不再次调用 ────────
(define calls 0)
(test-assert "no-overwrite: existing canonical short-circuits generator"
             (string=? %sample-id
                       (ensure-machine-id!
                        canonical2
                        (lambda ()
                          (set! calls (+ calls 1))
                          (error "generator must not be called")))))
(test-equal "no-overwrite: generator not called"
            0
            calls)
(test-equal "no-overwrite: canonical content untouched"
            (string-append %sample-id "\n")
            (read-text canonical2))
;; canonical 存在时生成器若输出另一个 ID 也绝不被接受：
(test-assert "no-overwrite: second identity never adopted"
             (string=? %sample-id
                       (ensure-machine-id! canonical2
                                           (lambda () "deadbeef00000000000000000000000000"))))
(test-equal "no-overwrite: canonical still first identity"
            (string-append %sample-id "\n")
            (read-text canonical2))

;; ── F. /etc/machine-id 损坏/空/缺失 → 投影自愈 ───────────────
(define heal (fresh-dir "self-heal"))
(define canonical-h (string-append heal "/persist/machine-id"))
(define etc-h (string-append heal "/etc/machine-id"))
(ensure-machine-id! canonical-h (lambda () %sample-id))
(project-machine-id! canonical-h etc-h)

(chmod etc-h #o644)
(call-with-output-file etc-h (lambda (port) (display "" port)))
(test-assert "self-heal: empty /etc/machine-id replaced"
             (string=? %sample-id
                       (project-machine-id! canonical-h etc-h)))
(test-equal "self-heal: content after empty"
            (string-append %sample-id "\n")
            (read-text etc-h))

(chmod etc-h #o644)
(call-with-output-file etc-h (lambda (port) (display "junk-content\n" port)))
(test-assert "self-heal: corrupt /etc/machine-id replaced"
             (string=? %sample-id
                       (project-machine-id! canonical-h etc-h)))
(test-equal "self-heal: content after corrupt"
            (string-append %sample-id "\n")
            (read-text etc-h))

(delete-file etc-h)
(test-assert "self-heal: missing /etc/machine-id restored"
             (string=? %sample-id
                       (project-machine-id! canonical-h etc-h)))

;; ── G. canonical 损坏 → fail closed ──────────────────────────
(define corrupt (fresh-dir "corrupt-canonical"))
(define canonical-c (string-append corrupt "/machine-id"))
(call-with-output-file canonical-c
                       (lambda (port) (display "not-a-machine-id\n" port)))
(test-assert "corrupt canonical: read reports invalid"
             (eq? 'invalid (read-machine-id-file canonical-c)))
(test-assert "corrupt canonical: ensure fails closed (raises)"
             (not (false-if-exception
                   (ensure-machine-id! canonical-c
                                       (lambda () %sample-id)))))
(test-equal "corrupt canonical: file NOT regenerated/overwritten"
            "not-a-machine-id\n"
            (read-text canonical-c))

;; ── H. dbus-uuidgen 包装 ─────────────────────────────────────
(define gen (fresh-dir "generator"))
(define fake-ok (write-fake-uuidgen gen "uuidgen-ok" %sample-id 0))
(define fake-fail (write-fake-uuidgen gen "uuidgen-fail" "whatever" 1))
(define fake-junk (write-fake-uuidgen gen "uuidgen-junk" "not-hex!" 0))

(test-equal "generator: ok output normalized"
            %sample-id
            (generate-machine-id fake-ok))
(test-assert "generator: non-zero exit raises"
             (not (false-if-exception (generate-machine-id fake-fail))))
(test-assert "generator: invalid output raises"
             (not (false-if-exception (generate-machine-id fake-junk))))

;; ── I. host 接线时序：restore 先于 D-Bus activation ──────────
(define (activation-gexps os)
  (service-value
   (fold-services (operating-system-services os)
                  #:target-type activation-service-type)))

(define (gexp-source g)
  (call-with-output-string (lambda (p) (write (gexp->approximate-sexp g) p))))

(define (gexp-index gexps marker)
  (list-index (lambda (g) (and (gexp? g)
                               (string-contains (gexp-source g) marker)))
              gexps))

(define %vm-activation-gexps (activation-gexps %vm-os))
(define vm-restore-idx (gexp-index %vm-activation-gexps "ensure-machine-id!"))
(define vm-dbus-idx (gexp-index %vm-activation-gexps "--ensure=/etc/machine-id"))

(test-assert "vm: machine-identity restore wired into activation"
             (and vm-restore-idx (>= vm-restore-idx 0)))
(test-assert "vm: dbus activation present (precondition of ordering)"
             (and vm-dbus-idx (>= vm-dbus-idx 0)))
(test-assert "vm: machine-identity restore runs BEFORE dbus-uuidgen --ensure"
             (and vm-restore-idx vm-dbus-idx
                  (< vm-restore-idx vm-dbus-idx)))
(format #t "  vm: restore at ~a, dbus --ensure at ~a~%"
        vm-restore-idx vm-dbus-idx)

(define %laptop-activation-gexps (activation-gexps %laptop-os))
(define laptop-restore-idx (gexp-index %laptop-activation-gexps "ensure-machine-id!"))
(define laptop-dbus-idx (gexp-index %laptop-activation-gexps "--ensure=/etc/machine-id"))

(test-assert "laptop: machine-identity restore wired into activation"
             (and laptop-restore-idx (>= laptop-restore-idx 0)))
(test-assert "laptop: dbus activation present (precondition of ordering)"
             (and laptop-dbus-idx (>= laptop-dbus-idx 0)))
(test-assert "laptop: machine-identity restore runs BEFORE dbus-uuidgen --ensure"
             (and laptop-restore-idx laptop-dbus-idx
                  (< laptop-restore-idx laptop-dbus-idx)))
(format #t "  laptop: restore at ~a, dbus --ensure at ~a~%"
        laptop-restore-idx laptop-dbus-idx)

;; activation gexp 可编译（gexp->script）
(test-assert "activation gexp compiles"
             (let ((out (false-if-exception
                         (gexp->script "machine-identity-activate"
                                       (machine-identity-activation)))))
               (and out #t)))

(cleanup!)

(test-end "machine-identity")
