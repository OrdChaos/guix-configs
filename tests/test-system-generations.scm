;;; system-generations.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg system system-generations)
             (guixcfg storage root-generation) ; generations-to-delete* 对照
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "system-generations")

;;; ── 纯保留算法（与 Btrfs 轴共用）

(test-group "system-generations-to-delete"
            (test-equal "keep=1 protects current+last-good, keeps newest"
                        '(0 3)
                        (system-generations-to-delete '(0 1 2 3 4) 2 1 1))
            (test-equal "keep large enough deletes nothing"
                        '()
                        (system-generations-to-delete '(0 1 2) 2 1 5))
            (test-equal "no last-good protects only current"
                        '(0 1)
                        (system-generations-to-delete '(0 1 2) 2 #f 0))
            (test-equal "current/last-good never deleted even when oldest"
                        '(3)
                        (system-generations-to-delete '(2 1 3) 2 1 0))
            (test-error "negative keep throws" #t
                        (system-generations-to-delete '(0 1) 1 #f -1))
            (test-equal "matches Btrfs axis algorithm"
                        (generations-to-delete* '(0 1 2 3) 3 2 1)
                        (system-generations-to-delete '(0 1 2 3) 3 2 1)))

;;; ── 文件系统读取（临时 profile）

(define %tmp-dir (string-append "/tmp/guixcfg-test-system-generations-"
                                (number->string (getpid))))
(define %tmp-profile (string-append %tmp-dir "/system"))
(define %tmp-boot-states (string-append %tmp-dir "/boot-states.scm"))

(define (make-generation! n)
  (symlink (string-append "/gnu/store/fake-system-" (number->string n))
           (string-append %tmp-profile "-" (number->string n) "-link")))

(define (cleanup!)
  (for-each (lambda (n)
              (false-if-exception
               (delete-file (string-append %tmp-profile "-"
                                           (number->string n) "-link"))))
            '(0 1 2 3 4))
  (false-if-exception (delete-file %tmp-profile))
  (false-if-exception (delete-file %tmp-boot-states))
  (false-if-exception (rmdir %tmp-dir)))

(dynamic-wind
 (lambda ()
   (false-if-exception (mkdir %tmp-dir))
   (for-each make-generation! '(0 1 2 3))
   (symlink "system-3-link" %tmp-profile))
 (lambda ()
   (test-equal "system-generation-numbers lists existing generations (sorted)"
               '(0 1 2 3)
               (system-generation-numbers %tmp-profile))
   (test-equal "system-current-generation reads the profile symlink"
               3
               (system-current-generation %tmp-profile))
   (test-equal "missing profile yields no generations"
               '()
               (system-generation-numbers (string-append %tmp-dir "/absent"))))
 cleanup!)

;;; ── 显式列表解析

(test-group "parse-generation-list"
            (test-equal "comma list sorted/deduped" '(1 2 5)
                        (parse-generation-list "5,1,2,1"))
            (test-equal "range" '(3 4 5)
                        (parse-generation-list "3..5"))
            (test-error "empty throws" #t (parse-generation-list ""))
            (test-error "non-numeric throws" #t (parse-generation-list "1,foo"))
            (test-error "reverse range throws" #t (parse-generation-list "5..3")))

;;; ── policy

(test-group "keep-for-host"
            (test-equal "vm policy" 3 (keep-for-host "vm"))
            (test-equal "laptop policy" 5 (keep-for-host "laptop"))
            (test-error "unknown host throws" #t (keep-for-host "nope")))

;;; ── argv

(test-group "argv"
            (test-equal "delete uses guix package -p (no bootloader reinstall)"
                        '("guix" "package" "-p" "/var/guix/profiles/system"
                                 "--delete-generations=0,3")
                        (delete-generations-argv "/var/guix/profiles/system"
                                                 '(0 3)))
            (test-error "empty delete list throws" #t
                        (delete-generations-argv "/var/guix/profiles/system" '())))

;;; ── plan（注入 profile 与 boot-state 路径；保护边界 fail closed）

(dynamic-wind
 (lambda ()
   (false-if-exception (mkdir %tmp-dir))
   (for-each make-generation! '(0 1 2 3 4))
   (symlink "system-4-link" %tmp-profile)
   (call-with-output-file %tmp-boot-states
                          (lambda (port)
                            (write '((format-version . 2)
                                     (last-good . ((generation . 2)
                                                   (system . "/gnu/store/fake-system-2")
                                                   (command-line . ""))))
                                   port))))
 (lambda ()
   (let ((plan (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:keep 1)))
     (test-equal "plan existing" '(0 1 2 3 4) (assq-ref plan 'existing))
     (test-equal "plan current" 4 (assq-ref plan 'current))
     (test-equal "plan last-good" 2 (assq-ref plan 'last-good))
     (test-eq "plan mode" 'keep (assq-ref plan 'mode))
     ;; protected = {4,2}；candidates = {0,1,3}；keep 1 最新（3）→ 删 0,1
     (test-equal "plan to-delete" '(0 1) (assq-ref plan 'to-delete)))
   (let ((plan (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:delete '(0 1))))
     (test-eq "explicit delete mode" 'delete (assq-ref plan 'mode))
     (test-equal "explicit delete list" '(0 1) (assq-ref plan 'to-delete)))
   (test-error "explicit delete refuses current" #t
               (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:delete '(4)))
   (test-error "explicit delete refuses last-good" #t
               (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:delete '(2)))
   (test-error "explicit delete refuses missing generation" #t
               (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:delete '(9)))
   (test-error "delete and keep mutually exclusive" #t
               (system-generation-plan #:profile %tmp-profile
                                       #:boot-states-path %tmp-boot-states
                                       #:keep 1 #:delete '(0))))
 cleanup!)

(test-end "system-generations")
