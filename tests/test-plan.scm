;;; plan.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage model)
             (guixcfg storage plan)
             (guixcfg storage policies)      ; %vm-storage-policy
             (srfi srfi-1)
             (srfi srfi-64))

(define %test-plan (storage-plan %vm-storage-policy "/dev/vda"))
(define %test-ids (map plan-step-id %test-plan))

;; 步骤 a 是否排在步骤 b 之前。
(define (step-before? a b)
  (< (list-index (lambda (id) (eq? id a)) %test-ids)
     (list-index (lambda (id) (eq? id b)) %test-ids)))

(test-begin "storage-plan")

(test-group "execution order (docs/operations/installation.md)"
            (test-assert "target confirmation first"       (eq? 'confirm-target (car %test-ids)))
            (test-assert "wipe before partition"      (step-before? 'wipe 'partition))
            (test-assert "wait for udev after partition"      (step-before? 'partition 'wait-udev))
            (test-assert "format only after udev ready"  (step-before? 'wait-udev 'format-esp))
            (test-assert "LUKS format before open" (step-before? 'luks-format 'luks-open))
            (test-assert "Btrfs only after unlock"   (step-before? 'luks-open 'format-btrfs))
            (test-assert "subvolumes after Btrfs top-level mount" (step-before? 'mount-top 'make-subvolume))
            (test-assert "persistent subvolumes before install root" (step-before? 'make-subvolume 'make-root-installing))
            (test-assert "swapfile before top-level unmount" (step-before? 'make-swapfile 'unmount-top))
            (test-assert "root mounted before persistent subvolumes" (step-before? 'mount-root 'mount-subvolume))
            (test-assert "persistent subvolumes before ESP"     (step-before? 'mount-subvolume 'mount-esp))
            (test-assert "machine facts after ESP mount" (step-before? 'mount-esp 'write-facts))
            (test-assert "facts written before ready"     (step-before? 'write-facts 'ready))
            (test-assert "ready last"         (eq? 'ready (last %test-ids))))

(test-group "content completeness"
            (test-equal "make-subvolume count equals persistent subvolume count"
                        (length %persist-subvolumes)
                        (length (filter (lambda (id) (eq? id 'make-subvolume)) %test-ids)))
            (test-equal "mount-subvolume count equals install-time mounted count"
                        (length (filter subvolume-mount-at-install?
                                        %persist-subvolumes))
                        (length (filter (lambda (id) (eq? id 'mount-subvolume)) %test-ids)))
            (test-assert "all mount points under /mnt"
                         (every (lambda (step)
                                  (or (not (memq (plan-step-id step) '(mount-root mount-subvolume mount-esp)))
                                      (string-prefix? "/mnt" (assq-ref (plan-step-detail step) 'target))))
                                %test-plan))
            (test-assert "swapfile uses policy size"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'make-swapfile)
                                     (= (assq-ref (plan-step-detail step) 'size)
                                        (host-storage-policy-swapfile-size %vm-storage-policy))))
                              %test-plan))
            (test-assert "partition step carries policy ESP size"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'partition)
                                     (= (assq-ref (plan-step-detail step) 'esp-size)
                                        (host-storage-policy-esp-size %vm-storage-policy))))
                              %test-plan))
            (test-assert "swapfile step uses subvolume name (@persist- prefix), not mount point"
                         (any (lambda (step)
                                (and (eq? (plan-step-id step) 'make-swapfile)
                                     (persist-subvolume-name?
                                      (assq-ref (plan-step-detail step) 'subvolume))))
                              %test-plan)))

(test-group "human-readable output"
            (let ((text (plan->text %test-plan)))
              (test-assert "includes mapper path" (string-contains text "/dev/mapper/cryptroot"))
              (test-assert "includes all persistent subvolume names"
                           (every (lambda (sv) (string-contains text (subvolume-name sv)))
                                  %persist-subvolumes))
              (test-assert "includes target device" (string-contains text "/dev/vda"))))

(test-end)
