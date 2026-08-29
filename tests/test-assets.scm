;;; 用户资源（avatar/wallpaper）声明式分发测试：
;;; (guixcfg home assets) + %guix-home 组装。
;;;
;;; 覆盖：
;;;   - 稳定目标路径事实（~/.local/share/avatars|backgrounds/）；
;;;   - %user-assets-service 经 home-files-service-type 挂入
;;;     %guix-home（thin assembly 组合）；
;;;   - 两个素材经 repository-file 物化进 store（内容为真实
;;;     PNG/JPEG 文件头，非空/非占位）；
;;;   - 组合 home-environment 构建产物含 files/ 下对应条目
;;;     （Home generation closure 携带资源，rollback 随 generation）。
;;;
;;; 网络：无。构建仅两个 local-file + 空 profile home derivation。

(use-modules (guix store)        ; open-connection
             (guix monads)       ; run-with-store
             (guix gexp)         ; lower-object、local-file?
             (guix derivations)  ; derivation->output-path、derivation?
             (gnu home)          ; home-environment
             (gnu home services) ; home-files-service-type
             (gnu services)      ; service-kind、service-type-name、service-value
             (ice-9 binary-ports) ; get-bytevector-n
             (srfi srfi-1)
             (srfi srfi-64)
             (guixcfg home assets)
             (guixcfg home user))

(test-runner-current (test-runner-simple))

(test-begin "assets")

;; ── 1. 稳定路径事实 ────────────────────────────────────────
(test-equal "avatar stable home path"
            ".local/share/avatars/avatar.png" %avatar-home-path)
(test-equal "wallpaper stable home path"
            ".local/share/backgrounds/wallpaper.jpg" %wallpaper-home-path)

;; ── 2. 服务组装进 %guix-home ───────────────────────────────
(define %assets-svc
  (find (lambda (s)
          (eq? 'user-assets (service-type-name (service-kind s))))
        (home-environment-services %guix-home)))

(test-assert "user-assets service composed into %guix-home" %assets-svc)

(test-equal "service declares exactly the two stable paths"
            (list %avatar-home-path %wallpaper-home-path)
            (map car (service-value %assets-svc)))

(test-assert "both sources are file-likes"
             (every local-file? (map cadr (service-value %assets-svc))))

(define (source-of target)
  (cadr (assoc target (service-value %assets-svc))))

;; ── 3. 素材物化进 store（真实内容）────────────────────────
(define %store (open-connection))

(define (materialize-file file-like)
  "local-file 的 lowering 直接把内容 intern 进 store（返回立即可读
  的 store 路径字符串，与 test-appearance 的 lower-text 同款）；对
  derivation 形态（防御性）仍走 build。"
  (let ((item (run-with-store %store (lower-object file-like))))
    (if (derivation? item)
      (begin
        (build-derivations %store (list item))
        (derivation->output-path item))
      item)))

(define (read-bytes path n)
  (call-with-input-file path
    (lambda (port) (get-bytevector-n port n))))

(define %avatar-out (materialize-file (source-of %avatar-home-path)))
(define %wallpaper-out (materialize-file (source-of %wallpaper-home-path)))

(test-assert "avatar materializes into the store"
             (file-exists? %avatar-out))
(test-assert "avatar is a real PNG (magic bytes)"
             (equal? (read-bytes %avatar-out 8)
                     #vu8(#x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A)))

(test-assert "wallpaper materializes into the store"
             (file-exists? %wallpaper-out))
(test-assert "wallpaper is a real JPEG (magic bytes)"
             (equal? (read-bytes %wallpaper-out 3)
                     #vu8(#xFF #xD8 #xFF)))

;; ── 4. Home generation closure 携带资源 ────────────────────
;; 最小组合 home（只含资源服务）：构建后 files/ 下必须出现两条目
;; ——home activation 的 symlink-manager 把这些条目链接进 $HOME。
(define %assets-only-home
  (home-environment
   (packages '())
   (services (list %user-assets-service))))

(define %home-drv (run-with-store %store (lower-object %assets-only-home)))
(build-derivations %store (list %home-drv))
(define %home-out (derivation->output-path %home-drv))

(test-assert "home generation files tree contains avatar entry"
             (file-exists?
              (string-append %home-out "/files/" %avatar-home-path)))
(test-assert "home generation files tree contains wallpaper entry"
             (file-exists?
              (string-append %home-out "/files/" %wallpaper-home-path)))

(test-end "assets")
