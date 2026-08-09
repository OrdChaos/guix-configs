;;; plan.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage model)
             (guixcfg storage plan)
             (srfi srfi-1)
             (srfi srfi-64))

(define %test-plan (storage-plan %vm-storage-policy "/dev/vda"))
(define %test-ids (map plan-step-id %test-plan))

;; 步骤 a 是否排在步骤 b 之前。
(define (step-before? a b)
  (< (list-index (lambda (id) (eq? id a)) %test-ids)
     (list-index (lambda (id) (eq? id b)) %test-ids)))

(test-begin "storage-plan")

(test-group "执行顺序（docs/installation.md 第 30 章流程）"
            (test-assert "确认目标在最前"       (eq? 'confirm-target (car %test-ids)))
            (test-assert "wipe 在分区之前"      (step-before? 'wipe 'partition))
            (test-assert "分区后等待 udev"      (step-before? 'partition 'wait-udev))
            (test-assert "udev 就位后才格式化"  (step-before? 'wait-udev 'format-esp))
            (test-assert "LUKS 格式化在解锁之前" (step-before? 'luks-format 'luks-open))
            (test-assert "解锁后才能建 Btrfs"   (step-before? 'luks-open 'format-btrfs))
            (test-assert "Btrfs 顶层挂载后建子卷" (step-before? 'mount-top 'make-subvolume))
            (test-assert "持久子卷先于安装期 root" (step-before? 'make-subvolume 'make-root-installing))
            (test-assert "swapfile 在卸载顶层之前" (step-before? 'make-swapfile 'unmount-top))
            (test-assert "先挂 root 再挂持久子卷" (step-before? 'mount-root 'mount-subvolume))
            (test-assert "持久子卷先于 ESP"     (step-before? 'mount-subvolume 'mount-esp))
            (test-assert "ESP 挂载后写机器事实" (step-before? 'mount-esp 'write-facts))
            (test-assert "事实在就绪前写完"     (step-before? 'write-facts 'ready))
            (test-assert "ready 在最后"         (eq? 'ready (last %test-ids))))

(test-group "内容完整性"
            (test-equal "建子卷步骤数等于持久子卷数"
                        (length %persist-subvolumes)
                        (length (filter (lambda (id) (eq? id 'make-subvolume)) %test-ids)))
            (test-equal "挂载子卷步骤数等于持久子卷数"
                        (length %persist-subvolumes)
                        (length (filter (lambda (id) (eq? id 'mount-subvolume)) %test-ids)))
            (test-assert "挂载点都在 /mnt 下"
                         (every (lambda (step)
                                  (or (not (memq (plan-step-id step) '(mount-root mount-subvolume mount-esp)))
                                      (string-prefix? "/mnt" (assq-ref (plan-step-detail step) 'target))))
                                %test-plan))
            (test-assert "swapfile 使用 policy 的大小"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'make-swapfile)
                                     (= (assq-ref (plan-step-detail step) 'size)
                                        (host-storage-policy-swapfile-size %vm-storage-policy))))
                              %test-plan))
            (test-assert "partition 步骤携带 policy 的 ESP 大小"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'partition)
                                     (= (assq-ref (plan-step-detail step) 'esp-size)
                                        (host-storage-policy-esp-size %vm-storage-policy))))
                              %test-plan))
            (test-assert "swapfile 步骤使用子卷名（@persist- 前缀），不是挂载点"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'make-swapfile)
                                     (persist-subvolume-name?
                                      (assq-ref (plan-step-detail step) 'subvolume))))
                              %test-plan)))

(test-group "人类可读输出"
            (let ((text (plan->text %test-plan)))
              (test-assert "包含 mapper 路径" (string-contains text "/dev/mapper/cryptroot"))
              (test-assert "包含所有持久子卷名"
                           (every (lambda (sv) (string-contains text (subvolume-name sv)))
                                  %persist-subvolumes))
              (test-assert "包含目标设备" (string-contains text "/dev/vda"))))

(test-end)
