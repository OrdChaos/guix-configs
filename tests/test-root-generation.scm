;;; root-generation.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage root-generation)
             (srfi srfi-64))

(test-begin "root-generation")

;;; ── 状态序列化（docs/storage.md 第 17.7 节）

(define %sample-state
  (root-state (next-generation 3)
              (current-generation 2)
              (last-good-generation 1)
              (created-at '((2 . 200) (1 . 100)))
              (boot-status 'trying)
              (source-template "@root-template")
              (system-revision "abc123")))

(test-group "状态 alist 序列化"
            (test-equal "state->alist → alist->state 往返"
                        (state->alist %sample-state)
                        (state->alist (alist->state (state->alist %sample-state))))
            
            (test-equal "缺省字段可省略（created-at/source-template/system-revision）"
                        '()
                        (root-state-created-at
                         (alist->state '((next-generation . 1)
                                         (current-generation . 0)
                                         (last-good-generation . #f)
                                         (boot-status . first-boot)))))
            
            (test-error "缺少必需字段即报错" #t
                        (alist->state '((next-generation . 1))))
            
            (test-error "boot-status 非法即报错" #t
                        (alist->state '((next-generation . 1)
                                        (current-generation . 0)
                                        (last-good-generation . #f)
                                        (boot-status . bogus))))
            
            (test-error "next-generation 非整数即报错" #t
                        (alist->state '((next-generation . "1")
                                        (current-generation . 0)
                                        (last-good-generation . #f)
                                        (boot-status . ok))))
            
            (test-equal "状态文件路径随 @persist-system 挂载点拼接"
                        "/btrfs-top/@persist-system/root-generations/state.scm"
                        (state-file-path "/btrfs-top/@persist-system")))

;;; ── 启动模式解析（第 17.6 节）

(test-group "rootmode= 解析"
            (test-eq "normal" 'normal
                     (boot-mode-kind (parse-boot-mode "normal")))
            (test-eq "recovery" 'recovery
                     (boot-mode-kind (parse-boot-mode "recovery")))
            (test-eq "keep 无编号" 'keep
                     (boot-mode-kind (parse-boot-mode "keep")))
            (test-assert "keep 无编号时 generation 为 #f"
                         (not (boot-mode-generation (parse-boot-mode "keep"))))
            (test-equal "keep:3" 3
                        (boot-mode-generation (parse-boot-mode "keep:3")))
            (test-assert "拒绝未知值" (not (parse-boot-mode "bogus")))
            (test-assert "拒绝 keep: 空编号" (not (parse-boot-mode "keep:")))
            (test-assert "拒绝 keep:-1" (not (parse-boot-mode "keep:-1"))))

;;; ── 启动决策（第 17.4–17.6 节）

(define %installed (initial-state 1000))   ; 装完未启动：current=0, next=1

(test-group "plan-boot"
            (test-group "首次启动用安装期建好的 @root-0（第 17.4 节）"
                        (let ((plan (plan-boot %installed %default-boot-mode 2000)))
                          (test-equal "目标是 @root-0"
                                      "@root-0" (boot-plan-target-subvolume plan))
                          (test-assert "不创建快照"
                                       (not (boot-plan-create-from-template? plan)))
                          (test-eq "状态置为 trying"
                                   'trying
                                   (root-state-boot-status
                                    (boot-plan-state-after plan)))))
            
            (test-group "正常启动从模板新建 generation（第 17.5 节）"
                        (let* ((running (confirm-boot %installed))  ; 模拟已确认
                                                                    (plan (plan-boot running %default-boot-mode 3000))
                                                                    (after (boot-plan-state-after plan)))
                          (test-equal "目标是 @root-1"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-assert "需要从模板创建快照"
                                       (boot-plan-create-from-template? plan))
                          (test-equal "next 前进到 2"
                                      2 (root-state-next-generation after))
                          (test-equal "current 变为 1"
                                      1 (root-state-current-generation after))
                          (test-equal "last-good 保持 0"
                                      0 (root-state-last-good-generation after))
                          (test-equal "created-at 记录新 generation"
                                      3000 (assq-ref (root-state-created-at after) 1))))
            
            (test-group "Keep 模式"
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "keep") 4000)))
                          (test-equal "复用 current（@root-2）"
                                      "@root-2" (boot-plan-target-subvolume plan))
                          (test-assert "不创建快照"
                                       (not (boot-plan-create-from-template? plan))))
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "keep:1") 4000)))
                          (test-equal "复用指定 @root-1"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-equal "current 变为 1"
                                      1 (root-state-current-generation
                                         (boot-plan-state-after plan))))
                        (test-error "keep 但无 current 时报错" #t
                                    (plan-boot (root-state (next-generation 0)
                                                           (current-generation #f)
                                                           (last-good-generation #f)
                                                           (boot-status 'ok))
                                               (parse-boot-mode "keep") 4000)))
            
            (test-group "Recovery 模式"
                        (let ((plan (plan-boot %sample-state (parse-boot-mode "recovery") 4000)))
                          (test-equal "回到 last-good（@root-1）"
                                      "@root-1" (boot-plan-target-subvolume plan))
                          (test-assert "不创建快照"
                                       (not (boot-plan-create-from-template? plan))))
                        (test-error "无 last-good 时报错" #t
                                    (plan-boot %installed (parse-boot-mode "recovery") 4000))))

;;; ── 用户态确认（第 17.4 节）

(test-group "confirm-boot"
            (let ((confirmed (confirm-boot %sample-state)))
              (test-equal "current 提升为 last-good"
                          2 (root-state-last-good-generation confirmed))
              (test-eq "状态置为 ok" 'ok (root-state-boot-status confirmed))
              (test-equal "next 不变" 3 (root-state-next-generation confirmed))))

;;; ── 清理（第 17.8 节）

(test-group "generations-to-delete"
            ;; %sample-state: current=2, last-good=1，均受保护；
            ;; candidates={0,3,4}，新的在前为 (4 3 0)
            (test-equal "keep=1：保留最新的 4，删 (0 3)"
                        '(0 3)
                        (generations-to-delete '(0 1 2 3 4) %sample-state 1))
            
            (test-equal "keep 足够大时不删"
                        '()
                        (generations-to-delete '(0 1 2) %sample-state 5))
            
            (test-equal "current/last-good 即使最旧也不删"
                        '(3)
                        (generations-to-delete '(2 1 3)
                                               (root-state (next-generation 4)
                                                           (current-generation 2)
                                                           (last-good-generation 1)
                                                           (boot-status 'ok))
                                               0)))

(test-end)
