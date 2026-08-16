;;; Guix Home stale pivot 保守判定的单元测试（H2/H3/H4 的函数级覆盖；
;;; H1/H5/H6 为 VM 集成场景）。
;;; 存在性/closure 语义检查通过 #:root 参数化在临时目录中构造 fake
;;; store closure 验证。

(use-modules (guixcfg home pivot)
             (ice-9 ftw)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define (with-temp-dir thunk)
  (let ((dir (mkdtemp "/tmp/guixcfg-pivot-test-XXXXXX")))
    (dynamic-wind
     (lambda () #t)
     (lambda () (thunk dir))
     (lambda ()
       (false-if-exception (delete-file-recursively dir))))))

;; 在 DIR 下构造 fake store home closure（形态正确 + 目录 + activate）。
(define (make-fake-home! dir)
  (let ((home (string-append
               dir "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home")))
    (mkdir home)
    (call-with-output-file (string-append home "/activate")
                           (lambda (port) (display "#!/bin/true\n" port)))
    home))

(test-begin "home-pivot")

;; absent：不存在的 pivot 是正常状态
(with-temp-dir
 (lambda (dir)
   (let ((p (string-append dir "/.guix-home.new")))
     (test-equal "absent pivot" 'absent (stale-pivot-disposition p))
     (test-equal "absent pivot removal is no-op"
                 'absent (remove-stale-pivot! p)))))

;; safe-stale-pivot：symlink 指向形态+存在性都合法的真实 closure
(with-temp-dir
 (lambda (dir)
   (let* ((p (string-append dir "/.guix-home.new"))
          (target (make-fake-home! dir)))
     (symlink target p)
     (test-equal "stale closure symlink" 'safe-stale-pivot
                 (stale-pivot-disposition p #:root dir))
     (test-equal "safe pivot removed" 'safe-stale-pivot
                 (remove-stale-pivot! p #:root dir))
     (test-equal "after removal: absent" 'absent
                 (stale-pivot-disposition p #:root dir)))))

;; 形态正确但 closure 不存在（generation 已 GC）→ unsafe
(with-temp-dir
 (lambda (dir)
   (let ((p (string-append dir "/.guix-home.new")))
     (symlink (string-append
               dir "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home") p)
     (test-equal "dangling store-home symlink is unsafe" 'unsafe
                 (stale-pivot-disposition p #:root dir)))))

;; 形态正确、目录存在，但没有 activate 入口 → 非真实 closure → unsafe
(with-temp-dir
 (lambda (dir)
   (let* ((p (string-append dir "/.guix-home.new"))
          (fake (string-append
                 dir "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home")))
     (mkdir fake)
     (symlink fake p)
     (test-equal "closure without activate is unsafe" 'unsafe
                 (stale-pivot-disposition p #:root dir)))))

;; unsafe：symlink 但 target 不是 store home（不可证明是 Guix Home pivot）
(with-temp-dir
 (lambda (dir)
   (let ((p (string-append dir "/.guix-home.new")))
     (symlink "/home/user/.config" p)
     (test-equal "non-store symlink is unsafe" 'unsafe
                 (stale-pivot-disposition p #:root dir))
     (test-equal "unsafe symlink NOT removed" 'unsafe
                 (remove-stale-pivot! p #:root dir))
     (test-assert "unsafe symlink still exists"
                  ;; dangling symlink：file-exists? follow 目标会 #f，用 lstat。
                  (false-if-exception (lstat p))))))

;; H3：普通文件 → fail closed，拒绝删除，文件保留
(with-temp-dir
 (lambda (dir)
   (let ((p (string-append dir "/.guix-home.new")))
     (call-with-output-file p (lambda (port) (display "user data" port)))
     (test-equal "plain file is unsafe" 'unsafe
                 (stale-pivot-disposition p))
     (test-equal "plain file NOT removed" 'unsafe
                 (remove-stale-pivot! p))
     (test-assert "plain file content preserved"
                  (and (file-exists? p)
                       (string=? "user data"
                                 (call-with-input-file p read-line)))))))

;; H4：目录 → fail closed
(with-temp-dir
 (lambda (dir)
   (let ((p (string-append dir "/.guix-home.new")))
     (mkdir p)
     (test-equal "directory is unsafe" 'unsafe
                 (stale-pivot-disposition p))
     (remove-stale-pivot! p)
     (test-assert "directory still exists" (file-exists? p)))))

;; 纯形态校验：拒绝近似但非法路径（hash 位数/前后缀必须精确）
(test-assert "rejects near-miss store paths (form only)"
             (not (any (lambda (s) (store-home-path-form? s "/gnu/store"))
                       '("/gnu/store/aaaa-home"                          ; hash 太短
                                                                         "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA-home" ; 大写
                                                                         "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-homex" ; 后缀错
                                                                         "/tmp/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home"
                                                                         "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home/"))))

(test-assert "accepts canonical store home form"
             (store-home-path-form?
              "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-home" "/gnu/store"))

(test-end "home-pivot")
