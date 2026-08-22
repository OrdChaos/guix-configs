;;; (guixcfg utils home-path) 直接测试：HOME consumer 中间父目录的
;;; 创建与 ownership 修复原语。真实文件系统操作（/tmp fixture，
;;; 当前用户 uid/gid——chown 到自身合法）。

(use-modules (guixcfg utils home-path)
             (guix build utils)    ; mkdir-p、delete-file-recursively
             (ice-9 ftw)           ; mkdtemp
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "home-path")

(define %tmp-root (mkdtemp "/tmp/guixcfg-home-path-XXXXXX"))
(define %home (string-append %tmp-root "/home/user"))
(define %uid (getuid))
(define %gid (getgid))

(mkdir-p %home)

;; ── 单层 consumer：没有中间父目录，无操作 ────────────────────
(ensure-home-parent-directories! %home "Documents" %uid %gid)
(test-assert "single-level consumer: leaf not created"
             (not (file-exists? (string-append %home "/Documents"))))

;; ── 多层 consumer：从浅到深建中间父目录，不碰叶子与 HOME ────
(ensure-home-parent-directories! %home ".local/share/keyrings" %uid %gid)
(test-assert "multi-level: shallow parent created"
             (file-exists? (string-append %home "/.local")))
(test-assert "multi-level: deep parent created"
             (file-exists? (string-append %home "/.local/share")))
(test-assert "multi-level: leaf not created"
             (not (file-exists? (string-append %home "/.local/share/keyrings"))))
(test-assert "multi-level: parents owned by target uid"
             (and (= %uid (stat:uid (stat (string-append %home "/.local"))))
                  (= %uid (stat:uid (stat (string-append %home "/.local/share"))))))

;; ── HOME 本身不被处理（存在、owner 未被改动到其它值）─────────
(test-assert "HOME directory untouched"
             (file-exists? %home))

;; ── 幂等：已存在目录时重复调用无异常、结果不变 ───────────────
(ensure-home-parent-directories! %home ".local/share/keyrings" %uid %gid)
(test-assert "idempotent: second call keeps parents"
             (and (file-exists? (string-append %home "/.local"))
                  (file-exists? (string-append %home "/.local/share"))
                  (not (file-exists? (string-append %home "/.local/share/keyrings")))))

;; 多层已存在 + 新层混合：已有层保留、新层补建
(ensure-home-parent-directories! %home "a/b/c" %uid %gid)
(test-assert "nested under existing parents"
             (and (file-exists? (string-append %home "/a/b"))
                  (not (file-exists? (string-append %home "/a/b/c")))))

;; ── defensive：绝对路径 consumer 拒绝（避免前导空段 chown HOME）──
(test-assert "absolute consumer rejected"
             (catch #t
               (lambda ()
                 (ensure-home-parent-directories! %home "/etc/x" %uid %gid)
                 #f)
               (lambda (key . args) #t)))
(test-assert "empty consumer rejected"
             (catch #t
               (lambda ()
                 (ensure-home-parent-directories! %home "" %uid %gid)
                 #f)
               (lambda (key . args) #t)))

;; ── 清理 ─────────────────────────────────────────────────────
(delete-file-recursively %tmp-root)

(test-end "home-path")
