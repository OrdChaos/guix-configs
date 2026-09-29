;;; Session infrastructure 测试：elogind 在 base/common 层、PAM 扩展、
;;; /run/user 生命周期由 system 提供（不由 Home/persistence 制造）。

(use-modules (gnu services)             ; service、service-kind、service-value、service-extension
             (gnu services desktop)     ; elogind-service-type
             (gnu system pam)           ; pam-root-service-type
             (gnu services base)        ; file-system-service-type、special-files-service-type
             (guixcfg system common)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "session")

(test-assert "elogind in %common-services (base/common layer)"
             (any (lambda (s) (eq? (service-kind s) elogind-service-type))
                  %common-services))

;; elogind-service-type 自动扩展 PAM（pam_elogind.so 进 session 链）——
;; SSH/tty 登录经 PAM 获得 /run/user/<uid> 与 XDG_RUNTIME_DIR。
(test-assert "elogind-service-type extends PAM"
             (any (lambda (ext)
                    (eq? (service-extension-target ext) pam-root-service-type))
                  (service-type-extensions elogind-service-type)))

;; elogind 同时声明 /run/user 等 file-systems（%elogind-file-systems
;; 经 file-system-service-type 扩展）——/run/user/<uid> 不持久化。
(test-assert "elogind-service-type declares /run/user file-systems"
             (any (lambda (ext)
                    (eq? (service-extension-target ext) file-system-service-type))
                  (service-type-extensions elogind-service-type)))

;; FHS glibc shim：prebuilt Wine runners（AAGL 下载）硬编码
;; /lib64/ld-linux-x86-64.so.2 且无 RPATH；/lib 必须指向 glibc 库目录，
;; 否则 wine 以 ENOENT 失败（Wine prefix 无法创建）。
(test-assert "FHS glibc compat special files declared in %common-services"
             (let* ((svc (find (lambda (s)
                                (eq? 'fhs-glibc-compat
                                     (service-type-name (service-kind s))))
                              %common-services))
                    (files (and svc (service-value svc))))
               (and files
                    (assoc-ref files "/lib")
                    (assoc-ref files "/lib64/ld-linux-x86-64.so.2"))))

(test-end "session")
