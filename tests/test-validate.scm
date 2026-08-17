;;; validate.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage model)
             (guixcfg storage validate)
             (guixcfg hosts vm)
             (srfi srfi-64))

;; 一个“好”的目标设备：整盘、未挂载、非系统盘、非 LiveCD、容量足够。
;; 布尔字段默认 #f，只需写出 by-id、path 和容量。
(define %good-facts
  (device-facts (path "/dev/vda")
                (by-id "/dev/disk/by-id/virtio-test")
                (size (gib 64))))

;; 坏情况用 (inherit ...) 派生：只写出要破坏的字段，其余继承好设备。
;; 这正是 define-record-type* 相对 SRFI-9 的核心便利之一。

;; 从失败列表中取出规则名。
(define (failure-names failures)
  (map check-failure-name failures))

(test-begin "storage-validate")

(test-group "目标设备校验（docs/architecture/storage.md）"
            (test-assert "好设备通过全部检查"
                         (null? (validate-target %good-facts %vm-storage-policy)))
            
            (test-equal "无法解析 by-id 被拒绝"
                        '(resolvable-by-id)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (by-id #f))
                                                        %vm-storage-policy)))
            
            (test-equal "分区设备被拒绝"
                        '(whole-disk)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (path "/dev/vda1")
                                                                      (partition? #t))
                                                        %vm-storage-policy)))
            
            (test-equal "已挂载设备被拒绝"
                        '(not-mounted)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (mounted? #t))
                                                        %vm-storage-policy)))
            
            (test-equal "当前系统盘被拒绝"
                        '(not-system-disk)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (system-disk? #t))
                                                        %vm-storage-policy)))
            
            (test-equal "LiveCD 介质被拒绝"
                        '(not-live-media)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (live-media? #t))
                                                        %vm-storage-policy)))
            
            (test-equal "容量不足被拒绝"
                        '(sufficient-size)
                        (failure-names (validate-target (device-facts (inherit %good-facts)
                                                                      (size (gib 8)))
                                                        %vm-storage-policy)))
            
            (test-assert "多项违规同时报告"
                         (let ((failures (validate-target (device-facts (inherit %good-facts)
                                                                        (by-id #f)
                                                                        (partition? #t)
                                                                        (mounted? #t)
                                                                        (size (gib 4)))
                                                          %vm-storage-policy)))
                           (>= (length failures) 4))))

(test-group "policy 自校验"
            (test-assert "内置 VM policy 合法"
                         (null? (validate-policy %vm-storage-policy)))
            (test-assert "内置 Laptop policy 合法"
                         (null? (validate-policy %laptop-storage-policy)))
            
            (test-equal "ESP 超出 2–4 GiB 范围"
                        '(esp-size-in-range)
                        (failure-names (validate-policy
                                        (host-storage-policy (inherit %vm-storage-policy)
                                                             (esp-size (gib 1))))))
            
            (test-equal "保留代数小于 2"
                        '(keep-at-least-two)
                        (failure-names (validate-policy
                                        (host-storage-policy (inherit %vm-storage-policy)
                                                             (keep-root-generations 1)))))
            
            (test-equal "磁盘下限装不下布局"
                        '(disk-fits-layout)
                        (failure-names (validate-policy
                                        (host-storage-policy (inherit %vm-storage-policy)
                                                             (esp-size (gib 4))
                                                             (min-disk-size (gib 10))
                                                             (swapfile-size (gib 8)))))))

(test-end)
