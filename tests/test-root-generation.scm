;;; root-generation.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage root-generation)
             (srfi srfi-64))

(test-begin "root-generation")

;;; ── 状态序列化（docs/architecture/storage.md（Root generation））

(define %sample-state
  (root-state (next-generation 3)
              (current-generation 2)
              (last-good-generation 1)
              (created-at '((2 . 200) (1 . 100)))
              (boot-status 'trying)
              (source-template "@root-template")))

(test-group "state alist serialization"
            (test-equal "state->alist -> alist->state roundtrip"
                        (state->alist %sample-state)
                        (state->alist (alist->state (state->alist %sample-state))))
            
            (test-equal "default fields optional (created-at/source-template)"
                        '()
                        (root-state-created-at
                         (alist->state '((next-generation . 1)
                                         (current-generation . 0)
                                         (last-good-generation . #f)
                                         (boot-status . first-boot)))))
            
            (test-error "missing required fields throw" #t
                        (alist->state '((next-generation . 1))))
            
            (test-error "invalid boot-status throws" #t
                        (alist->state '((next-generation . 1)
                                        (current-generation . 0)
                                        (last-good-generation . #f)
                                        (boot-status . bogus))))
            
            (test-error "non-integer next-generation throws" #t
                        (alist->state '((next-generation . "1")
                                        (current-generation . 0)
                                        (last-good-generation . #f)
                                        (boot-status . ok))))
            
            (test-equal "state file path joins @persist-system mount point"
                        "/btrfs-top/@persist-system/root-generations/state.scm"
                        (state-file-path "/btrfs-top/@persist-system")))

;;; ── 启动模式解析（第 17.6 节）

(test-group "rootmode= parsing"
            (test-eq "normal" 'normal
                     (boot-mode-kind (parse-boot-mode "normal")))
            (test-eq "recovery" 'recovery
                     (boot-mode-kind (parse-boot-mode "recovery")))
            (test-eq "keep without number" 'keep
                     (boot-mode-kind (parse-boot-mode "keep")))
            (test-assert "generation #f when keep has no number"
                         (not (boot-mode-generation (parse-boot-mode "keep"))))
            (test-equal "keep:3" 3
                        (boot-mode-generation (parse-boot-mode "keep:3")))
            (test-assert "rejects unknown value" (not (parse-boot-mode "bogus")))
            (test-assert "rejects keep: empty number" (not (parse-boot-mode "keep:")))
            (test-assert "rejects keep:-1" (not (parse-boot-mode "keep:-1")))
            (test-eq "previous:1 recognized as previous"
                     'previous
                     (boot-mode-kind (parse-boot-mode "previous:1")))
            (test-equal "previous:2 number"
                        2 (boot-mode-generation (parse-boot-mode "previous:2")))
            (test-assert "rejects previous:0" (not (parse-boot-mode "previous:0")))
            (test-assert "rejects bare previous:" (not (parse-boot-mode "previous:"))))

(test-group "previous-generation (relative selector anchored at latest boot)"
            (test-equal "K=1 is most recent boot"
                        4 (previous-generation '(0 1 2 3 4) 1))
            (test-equal "2nd from newest"
                        3 (previous-generation '(0 1 2 3 4) 2))
            (test-equal "3rd from newest"
                        2 (previous-generation '(0 1 2 3 4) 3))
            (test-assert "returns #f when fewer than K"
                         (not (previous-generation '(0 1) 3)))
            (test-assert "empty list returns #f"
                         (not (previous-generation '() 1))))

;;; ── 启动决策（第 17.4–17.6 节）

(define %installed (initial-state 1000))   ; 装完未启动：current=0, next=1

(test-group "plan-boot"
            (test-group "first boot uses install-time @root-0 (section 17.4)"
                        (let ((plan (plan-boot %installed %default-boot-mode 2000)))
                          (test-equal "targets @root-0"
                                      "@root-0" (boot-plan-target-subvolume plan))
                          (test-assert "no snapshot created"
                                       (not (boot-plan-create-from-template? plan)))
                          (test-eq "state set to trying"
                                   'trying
                                   (root-state-boot-status
                                    (boot-plan-state-after plan)))))
            
            (test-group "normal boot creates generation from template (section 17.5)"
                        (let* ((running (confirm-boot %installed))  ; 模拟已确认
                                                                    (plan (plan-boot running %default-boot-mode 3000))
                                                                    (after (boot-plan-state-after plan)))
                          (test-equal "targets @root-1"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-assert "snapshot from template required"
                                       (boot-plan-create-from-template? plan))
                          (test-equal "next advances to 2"
                                      2 (root-state-next-generation after))
                          (test-equal "current becomes 1"
                                      1 (root-state-current-generation after))
                          (test-equal "last-good stays 0"
                                      0 (root-state-last-good-generation after))
                          (test-equal "created-at records new generation"
                                      3000 (assq-ref (root-state-created-at after) 1))))
            
            (test-group "Keep mode"
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "keep") 4000)))
                          (test-equal "reuses current (@root-2)"
                                      "@root-2" (boot-plan-target-subvolume plan))
                          (test-assert "no snapshot created"
                                       (not (boot-plan-create-from-template? plan))))
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "keep:1") 4000)))
                          (test-equal "reuses specified @root-1"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-equal "current becomes 1"
                                      1 (root-state-current-generation
                                         (boot-plan-state-after plan))))
                        (test-error "keep without current throws" #t
                                    (plan-boot (root-state (next-generation 0)
                                                           (current-generation #f)
                                                           (last-good-generation #f)
                                                           (boot-status 'ok))
                                               (parse-boot-mode "keep") 4000)))
            
            (test-group "Recovery mode"
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "recovery") 4000)))
                          (test-equal "returns to last-good (@root-1)"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-assert "no snapshot created"
                                       (not (boot-plan-create-from-template? plan))))
                        (test-error "no last-good throws" #t
                                    (plan-boot %installed (parse-boot-mode "recovery") 4000))))

;;; ── 用户态确认（第 17.4 节）

(test-group "confirm-boot"
            (let ((confirmed (confirm-boot %sample-state)))
              (test-equal "current promoted to last-good"
                          2 (root-state-last-good-generation confirmed))
              (test-eq "state set to ok" 'ok (root-state-boot-status confirmed))
              (test-equal "next unchanged" 3 (root-state-next-generation confirmed))))

;;; ── 清理（第 17.8 节）

(test-group "generations-to-delete"
            ;; %sample-state: current=2, last-good=1，均受保护；
            ;; candidates={0,3,4}，新的在前为 (4 3 0)
            (test-equal "keep=1: keeps newest 4, deletes (0 3)"
                        '(0 3)
                        (generations-to-delete '(0 1 2 3 4) %sample-state 1))
            
            (test-equal "nothing deleted when keep large enough"
                        '()
                        (generations-to-delete '(0 1 2) %sample-state 5))
            
            (test-equal "current/last-good never deleted even when oldest"
                        '(3)
                        (generations-to-delete '(2 1 3)
                                               (root-state (next-generation 4)
                                                           (current-generation 2)
                                                           (last-good-generation 1)
                                                           (boot-status 'ok))
                                               0)))

(test-end)

;;; ── 状态文件 IO：原子写与 .prev 回退（真实文件系统，写 /tmp）

(test-begin "root-generation-io")

(define %tmp-state
  (string-append "/tmp/guixcfg-test-state-"
                 (number->string (getpid)) ".scm"))

(test-group "write-state!/read-state"
            (dynamic-wind
             (const #t)
             (lambda ()
               ;; 首次写入
               (write-state! %tmp-state %sample-state)
               (test-equal "written then read back"
                           (state->alist %sample-state)
                           (state->alist (read-state %tmp-state)))
               
               ;; 覆盖写入：旧内容成为 .prev
               (let ((newer (confirm-boot %sample-state)))
                 (write-state! %tmp-state newer)
                 (test-eq "new state read after overwrite"
                          'ok (root-state-boot-status (read-state %tmp-state)))
                 
                 ;; 主文件损坏（模拟断电半截文件）→ 回退 .prev
                 (call-with-output-file %tmp-state
                                        (lambda (port) (display "((broken" port)))
                 (test-eq "falls back to .prev when main file corrupt"
                          'trying
                          (root-state-boot-status (read-state %tmp-state))))
               
               ;; 主文件不存在但 .prev 在 → 也能读
               (delete-file %tmp-state)
               (test-eq "falls back to .prev when main file missing"
                        'trying
                        (root-state-boot-status (read-state %tmp-state)))
               
               ;; 都不在 → 报错
               (delete-file (string-append %tmp-state ".prev"))
               (test-error "throws when all missing" #t (read-state %tmp-state)))
             (lambda ()
               (false-if-exception (delete-file %tmp-state))
               (false-if-exception
                (delete-file (string-append %tmp-state ".prev")))
               (false-if-exception
                (delete-file (string-append %tmp-state ".new"))))))

(test-group "prune-created-at"
            (let ((pruned (prune-created-at %sample-state '(1 2))))
              (test-equal "keeps metadata only for existing generations"
                          '((2 . 200) (1 . 100))
                          (root-state-created-at pruned))
              (test-equal "other fields unchanged"
                          3 (root-state-next-generation pruned)))
            (test-equal "created-at cleared when all deleted"
                        '()
                        (root-state-created-at
                         (prune-created-at %sample-state '()))))

(test-end)
