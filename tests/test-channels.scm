;;; (guixcfg utils channels) 结构兼容测试。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。
;;;
;;; 覆盖设计决策记录要求的 7 个语义：revision 不参与比较；url /
;;; branch / introduction 任一不同即不兼容；单侧多余 channel 不兼容；
;;; 顺序无关；无 introduction 的频道（bluebox）双侧一致即兼容。

(use-modules (guixcfg utils channels)
             (srfi srfi-64)
             (srfi srfi-1)
             (srfi srfi-26))

(test-runner-current (test-runner-simple))

(define (mk-decl fields)
  "把字段列表 ((name guix) (url ...) ...) 包成 (channel ...) 再解析
为 alist——同时覆盖解析路径。"
  (channel-declaration-alist (cons 'channel fields)))

(define %base-fields
  '((name guix)
    (url "https://codeberg.org/guix/guix.git")
    (branch "master")
    (introduction (make-channel-introduction
                   "9edb3f66fd807b096b48283debdcddccfea34bad"
                   (openpgp-fingerprint
                    "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))

(define (replace-field fields key value)
  (map (lambda (kv) (if (eq? (car kv) key) (list key value) kv)) fields))

(test-begin "channels")

;; 1. 相同结构 + 不同 revision → 兼容（commit 不参与 identity）。
(test-assert "same structure, different commit: compatible"
             (channel-declaration-sets-compatible?
              (list (mk-decl %base-fields))
              (list (mk-decl (append %base-fields '((commit "different")))))))

;; 2. URL 不同 → 不兼容。
(test-assert "different url: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields))
                   (list (mk-decl (replace-field %base-fields
                                                 'url "https://evil.example/guix"))))))

;; 3. branch 不同 → 不兼容。
(test-assert "different branch: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields))
                   (list (mk-decl (replace-field %base-fields 'branch "trunk"))))))

;; 4. introduction 不同 → 不兼容。
(test-assert "different introduction: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields))
                   (list (mk-decl
                          (replace-field
                           %base-fields
                           'introduction
                           '(make-channel-introduction
                             "other-commit"
                             (openpgp-fingerprint "AAAA BBBB"))))))))

;; 5. lock 多 channel → 不兼容。
(test-assert "lock has extra channel: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields))
                   (list (mk-decl %base-fields)
                         (mk-decl '((name bluebox)
                                    (url "https://codeberg.org/lapislazuli/bluebox")
                                    (branch "main")
                                    (commit "x")))))))

;; 6. channels.scm 多 channel → 不兼容。
(test-assert "channels.scm has extra channel: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields)
                         (mk-decl '((name bluebox)
                                    (url "https://codeberg.org/lapislazuli/bluebox")
                                    (branch "main"))))
                   (list (mk-decl %base-fields)))))

;; 7. 顺序不同但集合一致 → 兼容（按语义集合比较）。
(test-assert "same set, different order: compatible"
             (let ((a (mk-decl %base-fields))
                   (b (mk-decl '((name bluebox)
                                 (url "https://codeberg.org/lapislazuli/bluebox")
                                 (branch "main")))))
               (channel-declaration-sets-compatible? (list a b) (list b a))))

;; 无 introduction 的频道（bluebox 现状）：双侧一致 → 兼容；一侧有
;; 一侧无 → 不兼容。
(test-assert "no introduction on both sides: compatible"
             (channel-declaration-sets-compatible?
              (list (mk-decl '((name bluebox)
                               (url "https://codeberg.org/lapislazuli/bluebox")
                               (branch "main"))))
              (list (mk-decl '((name bluebox)
                               (url "https://codeberg.org/lapislazuli/bluebox")
                               (branch "main")
                               (commit "7162877"))))))

(test-assert "introduction only on one side: incompatible"
             (not (channel-declaration-sets-compatible?
                   (list (mk-decl %base-fields))
                   (list (mk-decl (filter (lambda (kv) (not (eq? (car kv) 'introduction)))
                                          %base-fields))))))

;; 仓库自身两个文件的结构一致性（锁与声明必须同步维护）。
(test-assert "repository channels.scm vs channels.lock.scm compatible"
             (channel-declaration-sets-compatible?
              (read-channel-declarations "channels.scm")
              (read-channel-declarations "channels.lock.scm")))

(test-end)
