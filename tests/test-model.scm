;;; model.scm 的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage model)
             (guixcfg hosts vm)
             (guixcfg hosts laptop)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "storage-model")

(test-group "persistent subvolumes (docs/architecture/storage.md)"
            (test-equal "fixed 8 persistent subvolumes"
                        8 (length %persist-subvolumes))
            
            (test-assert "all use @persist- prefix (section 10.1)"
                         (every (lambda (sv) (persist-subvolume-name? (subvolume-name sv)))
                                %persist-subvolumes))
            
            (test-assert "mount points under /persist or standard exception paths (section 10.2)"
                         (every (lambda (sv)
                                  (let ((mp (subvolume-mount-point sv)))
                                    (or (string-prefix? "/persist/" mp)
                                        (member mp '("/gnu/store" "/var/guix")))))
                                %persist-subvolumes))
            
            (test-assert "subvolume names unique"
                         (let ((names (map subvolume-name %persist-subvolumes)))
                           (= (length names) (length (delete-duplicates names)))))
            
            (test-assert "mount points unique"
                         (let ((mps (map subvolume-mount-point %persist-subvolumes)))
                           (= (length mps) (length (delete-duplicates mps))))))

(test-group "root generation naming (section 17.1)"
            (test-equal "numbers not zero-padded"
                        "@root-12" (root-generation-name 12))
            (test-equal "@root-0 valid"
                        "@root-0" (root-generation-name 0))
            
            (test-equal "parses @root-12" 12 (parse-root-generation "@root-12"))
            (test-equal "parses @root-0" 0 (parse-root-generation "@root-0"))
            (test-assert "rejects zero-padded @root-01" (not (parse-root-generation "@root-01")))
            (test-assert "rejects @root-template" (not (parse-root-generation "@root-template")))
            (test-assert "rejects @root-installing" (not (parse-root-generation "@root-installing")))
            (test-assert "rejects empty suffix @root-" (not (parse-root-generation "@root-")))
            (test-assert "rejects missing prefix" (not (parse-root-generation "root-3"))))

(test-group "host policy instances (docs/architecture/storage.md, defined in each host module)"
            (test-eq "VM policy name" 'vm (host-storage-policy-name %vm-storage-policy))
            (test-eq "Laptop policy name" 'laptop (host-storage-policy-name %laptop-storage-policy))
            (test-assert "both policies' ESP within 2-4 GiB range"
                         (every (lambda (p) (<= %esp-min-size
                                                (host-storage-policy-esp-size p)
                                                %esp-max-size))
                                (list %vm-storage-policy %laptop-storage-policy))))


;; ── persist-mount-point：/persist/* 语义路径单一 authority ────
(test-group "persist semantic mount points (single authority)"
            (test-equal "@persist-system mount"
                        "/persist/system" (persist-mount-point "@persist-system"))
            (test-equal "@persist-data-home mount"
                        "/persist/data-home" (persist-mount-point "@persist-data-home"))
            (test-equal "@persist-data-app mount"
                        "/persist/data-app" (persist-mount-point "@persist-data-app"))
            (test-equal "@persist-data-nobackup mount"
                        "/persist/data-nobackup" (persist-mount-point "@persist-data-nobackup"))
            (test-equal "@persist-gnu-store mount"
                        "/gnu/store" (persist-mount-point "@persist-gnu-store"))
            (test-assert "unknown persist subvolume rejected"
                         (catch #t
                           (lambda () (persist-mount-point "@persist-bogus") #f)
                           (lambda (k . a) #t)))
            ;; 与 %persist-subvolumes 记录一致（authority 未漂移）
            (test-assert "every subvolume resolvable via persist-mount-point"
                         (every (lambda (s)
                                  (string=? (subvolume-mount-point s)
                                            (persist-mount-point (subvolume-name s))))
                                %persist-subvolumes)))

(test-end)
