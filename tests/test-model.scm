;;; model.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage model)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "storage-model")

(test-group "持久子卷（docs/architecture/storage.md（持久子卷））"
            (test-equal "固定 8 个持久子卷"
                        8 (length %persist-subvolumes))
            
            (test-assert "全部使用 @persist- 前缀（第 10.1 节）"
                         (every (lambda (sv) (persist-subvolume-name? (subvolume-name sv)))
                                %persist-subvolumes))
            
            (test-assert "挂载点在 /persist 下，或属于标准例外路径（第 10.2 节）"
                         (every (lambda (sv)
                                  (let ((mp (subvolume-mount-point sv)))
                                    (or (string-prefix? "/persist/" mp)
                                        (member mp '("/gnu/store" "/var/guix")))))
                                %persist-subvolumes))
            
            (test-assert "子卷名不重复"
                         (let ((names (map subvolume-name %persist-subvolumes)))
                           (= (length names) (length (delete-duplicates names)))))
            
            (test-assert "挂载点不重复"
                         (let ((mps (map subvolume-mount-point %persist-subvolumes)))
                           (= (length mps) (length (delete-duplicates mps))))))

(test-group "root generation 命名（第 17.1 节）"
            (test-equal "编号不补零"
                        "@root-12" (root-generation-name 12))
            (test-equal "@root-0 合法"
                        "@root-0" (root-generation-name 0))
            
            (test-equal "解析 @root-12" 12 (parse-root-generation "@root-12"))
            (test-equal "解析 @root-0" 0 (parse-root-generation "@root-0"))
            (test-assert "拒绝补零 @root-01" (not (parse-root-generation "@root-01")))
            (test-assert "拒绝 @root-template" (not (parse-root-generation "@root-template")))
            (test-assert "拒绝 @root-installing" (not (parse-root-generation "@root-installing")))
            (test-assert "拒绝空后缀 @root-" (not (parse-root-generation "@root-")))
            (test-assert "拒绝无前缀" (not (parse-root-generation "root-3"))))

(test-group "host policy 实例（docs/architecture/storage.md（持久子卷），定义在各自 host 模块）"
            (test-eq "VM policy 名字" 'vm (host-storage-policy-name %vm-storage-policy))
            (test-eq "Laptop policy 名字" 'laptop (host-storage-policy-name %laptop-storage-policy))
            (test-assert "两个 policy 的 ESP 都在 2–4 GiB 范围内"
                         (every (lambda (p) (<= %esp-min-size
                                                (host-storage-policy-esp-size p)
                                                %esp-max-size))
                                (list %vm-storage-policy %laptop-storage-policy))))

(test-end)
