;;; User Profile 拆分测试（docs/architecture/secrets.md）：host 只 select，
;;; %primary-user 是结构事实的唯一 authoritative source；password 为
;;; #f（hash 由 install secret 注入，不进 evaluation/store）。

(use-modules (gnu system accounts)      ; user-account 访问器
             (guixcfg users user)
             (ice-9 rdelim)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "users")

;; U2：结构事实唯一来源
(test-equal "primary user name" "user" (user-profile-name %primary-user))
(test-equal "primary user uid" 1000 (user-profile-uid %primary-user))
(test-equal "primary user group" "users" (user-profile-group %primary-user))
(test-equal "primary user supplementary groups"
            '("wheel" "netdev")
            (user-profile-supplementary-groups %primary-user))
(test-equal "primary user home" "/home/user"
            (user-profile-home-directory %primary-user))
(test-equal "password secret is a logical reference"
            'primary-user-password (user-profile-password-secret %primary-user))

;; 生成的 user-account：password 恒为 #f（hash 不进 evaluator/store）
(define acct (primary-user-account))
(test-equal "account name from profile" "user" (user-account-name acct))
(test-equal "account uid from profile" 1000 (user-account-uid acct))
(test-assert "account password is #f (no hash in evaluation)"
             (not (user-account-password acct)))

;; U1：host 定义不再含 user 结构事实/password hash（文本级检查）
(define (file-contains? path pattern)
  (call-with-input-file path
                        (lambda (port)
                          (let loop ((line (read-line port)))
                            (cond ((eof-object? line) #f)
                              ((string-contains line pattern) #t)
                              (else (loop (read-line port))))))))

(test-assert "hosts/vm.scm contains no password hash literal"
             (not (file-contains? "modules/guixcfg/hosts/vm.scm" "(password \"$")))
(test-assert "hosts/vm.scm references primary user profile"
             (file-contains? "modules/guixcfg/hosts/vm.scm" "%primary-user"))

(test-end "users")
