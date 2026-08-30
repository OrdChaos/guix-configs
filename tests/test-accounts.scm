;;; Account databases 投影测试（modules/guixcfg/system/accounts.scm）。
;;;
;;; 背景：上游 (gnu build activation)::activate-users+groups 把数据库
;;; 写入包在 with-file-lock（fcntl-flock FFI）里，boot 环境该 FFI 求值
;;; 失败 → /etc/passwd|group|shadow 空/缺失 → 所有 getpw 失败 → readiness
;;; 卡死。本测试验证：
;;;   A. %vm-os 折叠出的完整 account 列表（root + user + 服务贡献账号）；
;;;   B. account-databases-service 挂进 activation-service-type；
;;;   C. activation gexp 是纯 Scheme 写库（无 with-file-lock /
;;;      activate-users+groups），用的就是 user+group-databases +
;;;      write-passwd/group/shadow；
;;;   D. 纯 Scheme 计算对真实 account 列表产出正确 passwd/group 内容。

(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (gnu system)            ; operating-system-services
             (gnu services)
             (gnu system shadow)     ; account-service-type
             (gnu system accounts)   ; user-account / user-group
             (gnu build accounts)    ; user+group-databases、write-*
             (guix gexp)
             (guixcfg system accounts)
             (guixcfg hosts vm)
             (guixcfg users user)    ; %primary-user（主用户名权威）
             (ice-9 receive)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "accounts")

(define (account-list os)
  "OS 的完整 account+group 列表（account-service-type 折叠值）。"
  (service-value
   (fold-services (operating-system-services os)
                  #:target-type account-service-type)))

;; ── A. 完整 account 列表 ─────────────────────────────────────────
;; 折叠必须包含 root、primary user、服务贡献账号（guixbuilders、
;; sshd、dhcpcd、messagebus、polkitd）——与 store 内
;; activate-users+groups 序列化的账号集合一致。
(define %vm-accounts+groups (account-list %vm-os))
;; 主用户名从 %primary-user 推导（AGENT.md §13：唯一权威来源，
;; 测试不硬编码具体用户名）。
(define %account-test-user (user-profile-name %primary-user))

(define acct-names
  (map user-account-name (filter user-account? %vm-accounts+groups)))
(define group-names
  (map user-group-name (filter user-group? %vm-accounts+groups)))

(test-assert "folded accounts include root"
             (member "root" acct-names))
(test-assert "folded accounts include primary user"
             (member %account-test-user acct-names))
(test-assert "folded accounts include guix builders"
             (member "guixbuilder01" acct-names))
(test-assert "folded accounts include sshd"
             (member "sshd" acct-names))
(test-assert "folded accounts include messagebus"
             (member "messagebus" acct-names))
(test-assert "folded accounts include polkitd"
             (member "polkitd" acct-names))
(test-assert "folded groups include wheel"
             (member "wheel" group-names))
(test-assert "folded groups include guixbuild"
             (member "guixbuild" group-names))

;; primary user 的 UID 必须保留声明值 1000。
(test-equal "primary user keeps uid 1000"
            1000
            (user-account-uid
             (find (lambda (a) (string=? %account-test-user
                                         (user-account-name a)))
                   (filter user-account? %vm-accounts+groups))))

;; ── B. 服务接线 ─────────────────────────────────────────────────
;; account-databases-service 是 activation-service-type 的扩展，OS 的
;; activation 值里必须包含它（激活脚本会运行纯 Scheme 投影）。
(define activation-gexps
  (service-value
   (fold-services (operating-system-services %vm-os)
                  #:target-type activation-service-type)))

;; gexp 的 source 形式（gexp 记录打印器会 false-if-exception 吞掉正文，
;; 用导出的 approximate-sexp 拿可搜索的 sexp）。
(define (gexp-source g)
  (call-with-output-string (lambda (p) (write (gexp->approximate-sexp g) p))))

(test-assert "OS activation includes account-databases projection"
             (any (lambda (g)
                    ;; 投影 gexp 正文里必须引用纯写库入口 write-passwd。
                    (and (gexp? g)
                         (string-contains (gexp-source g) "write-passwd")))
                  activation-gexps))

;; ── C. 纯 Scheme 语义（无 FFI flock）─────────────────────────────
;; 投影 gexp 必须绕开上游 activate-users+groups / with-file-lock。
(define projection-gexp
  (find (lambda (g)
          (and (gexp? g)
               (string-contains (gexp-source g) "write-passwd")))
        activation-gexps))

(test-assert "projection uses pure-Scheme user+group-databases"
             (let ((s (gexp-source projection-gexp)))
               (and (string-contains s "user+group-databases")
                    (string-contains s "write-group")
                    (string-contains s "write-shadow"))))

(test-assert "projection does NOT use upstream flock activation"
             (let ((s (gexp-source projection-gexp)))
               (not (or (string-contains s "with-file-lock")
                        (string-contains s "activate-users+groups")))))

;; 顺序语义：投影必须排在所有 getpw 依赖方之前（activation 脚本顺序 =
;; fold-services 对 activation-service-type 的值顺序）。上游 broken
;; users+groups 步骤（essential）先跑并在 guard 下失败，我们的纯
;; Scheme 投影紧跟其后，任何 user activation 中的 getpw（如
;; user-persistence、guix-home）都看到完整数据库。
;; 注：投影自身也调用 getpwnam（写库后才建 home），不算消费者。
(test-assert "projection runs before any getpw-using activation"
             (let* ((index (lambda (pred)
                             (list-index pred activation-gexps)))
                    (proj-idx (index (lambda (g)
                                       (string-contains (gexp-source g) "write-passwd"))))
                    (consumers (filter-map (lambda (i)
                                             (and (not (= i proj-idx))
                                                  (string-contains (gexp-source
                                                                    (list-ref activation-gexps i))
                                                                   "getpw")
                                                  i))
                                           (iota (length activation-gexps)))))
               (format #t "  projection at ~a, getpw consumers at ~a~%"
                       proj-idx consumers)
               (and proj-idx
                    (every (lambda (i) (< proj-idx i)) consumers))))

;; ── D. 纯 Scheme 计算产出正确内容 ────────────────────────────────
;; 用真实 account 列表（shell 取字符串形式，模拟 boot 时 sexp 重建后
;; 的 record）计算 passwd/group，断言关键条目格式正确。
(define (string-shell user)
  (let ((s (user-account-shell user)))
    (if (string? s)
      s
      ;; gexp 未 lowering 时是 file-append；boot 时经 sexp->user-account
      ;; 重建后是 store 路径字符串。这里用占位路径验证格式。
      "/gnu/store/00000000000000000000000000000000-bash-5.2.37/bin/bash")))

(define (materialize user)
  (user-account
   (inherit user)
   (shell (string-shell user))))

(define materialized
  (map materialize (filter user-account? %vm-accounts+groups)))

(receive (groups passwd shadow)
         (user+group-databases materialized
                               (filter user-group? %vm-accounts+groups)
                               #:current-passwd '()
                               #:current-groups '()
                               #:current-shadow '())
         (define (entry-names entries getter)
           (map getter entries))
         
         (test-assert "passwd has root entry with uid 0"
                      (let ((root (find (lambda (e)
                                          (string=? "root" (password-entry-name e)))
                                        passwd)))
                        (and root (= 0 (password-entry-uid root)))))
         (test-assert "passwd has user entry with uid 1000"
                      (let ((user-e (find (lambda (e)
                                            (string=? %account-test-user
                                                      (password-entry-name e)))
                                          passwd)))
                        (and user-e (= 1000 (password-entry-uid user-e)))))
         (test-assert "shadow has entries for all users"
                      (= (length passwd) (length shadow)))
         (test-assert "wheel group includes user"
                      (let ((wheel (find (lambda (e)
                                           (string=? "wheel" (group-entry-name e)))
                                         groups)))
                        (and wheel (member %account-test-user
                                           (group-entry-members wheel))))))

(test-end "accounts")
