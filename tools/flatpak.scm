;;; Flatpak 显式运维入口（tooling plane——仓库内 CLI，唯一允许联网
;;; 的地方；docs/architecture/flatpak.md（operations））。
;;;
;;; 用法（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- sync
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- status [--refresh]
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update-runtimes
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- remove <logical-name>
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- remote-replace <remote-name>
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- gc
;;;
;;; 语义（reconcile.scm 头部）：sync 只增不删；status 默认离线；
;;; update 显式 ref 列表；remove ≠ purge；gc 显式维护。
;;; remote-replace 是唯一的换源入口：显式删除 + 按声明重建
;;; （sync 的 drift 检查永远 fail-loud，绝不静默改 trust root——
;;; 换源是修改已有 mutable state，必须由用户显式发起）。
;;; 一切操作 --user scope。reconfigure/boot/login 与网络零耦合。
;;;
;;; bootstrap descriptor：本入口从 registry 的 remote 声明 + vendored
;;; 公开 keyring 生成临时 .flatpakrepo（model 的纯函数
;;; flatpak-remote-descriptor-text），交给 reconcile 的
;;; flatpak-bootstrap-remote!（add --from → remote-modify --url
;;; canonicalize）。不存在手写 descriptor 文件——URL 只有
;;; repository-url 一个声明源。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg flatpak model)
             (guixcfg flatpak registry)
             (guixcfg flatpak reconcile)
             (ice-9 format)
             (ice-9 match)
             (ice-9 binary-ports)  ; get-bytevector-all
             (ice-9 rdelim)        ; read-string
             (srfi srfi-1))

(define %flatpak-dir
  (string-append (getcwd) "/modules/guixcfg/flatpak/"))

(define (remote-key-bytes remote)
  "REMOTE 的 vendored 公开 keyring 字节（trust material；文件路径
相对 flatpak 模块目录）。"
  (call-with-input-file
   (string-append %flatpak-dir (flatpak-remote-key-file remote))
   (lambda (port) (get-bytevector-all port))))

(define (remote-descriptor-path remote)
  "把 REMOTE 的声明 + keyring 生成临时 .flatpakrepo 并返回其路径
（tooling plane：tools 从 checkout 运行，临时文件放 /tmp，每次
调用重写）。"
  (let ((path (string-append "/tmp/guixcfg-flatpak-"
                             (symbol->string (flatpak-remote-name remote))
                             ".flatpakrepo")))
    (call-with-output-file path
      (lambda (port)
        (display (flatpak-remote-descriptor-text
                  remote (remote-key-bytes remote))
                 port)))
    path))

(define (usage)
  (format #t "Usage:
  flatpak sync                       ensure declared remotes and selected apps (add-only)
  flatpak status [--refresh]         show declared/installed state (offline; --refresh queries remotes)
  flatpak update                     update unpinned selected+installed apps (explicit refs only)
  flatpak update-runtimes            update installed runtimes (explicit refs only)
  flatpak remove <logical-name>      uninstall one catalog application (user data preserved)
  flatpak remote-replace <name>      explicit source switch: delete + rebuild remote from declaration
  flatpak gc                         maintenance: remove unused runtimes + repair installation~%"))

(define (main args)
  ;; install/export 时 flatpak 用 FLATPAK_BINARY 写绝对 Exec
  ;; （DBusActivatable desktop entries 在 CWD=/、无 PATH 的
  ;; activation 环境下也能启动）。
  (setenv "FLATPAK_BINARY" (flatpak-binary))
  (match (cdr args)
         (("sync")
          (flatpak-sync #:flatpakrepo
                        (remote-descriptor-path (car %flatpak-remotes))))
         (("status")         (flatpak-status))
         (("status" "--refresh") (flatpak-status #:refresh? #t))
         (("update")         (flatpak-update))
         (("update-runtimes") (flatpak-update-runtimes))
         (("remove" name)    (flatpak-remove (string->symbol name)))
         (("remote-replace" name)
          (flatpak-replace-remote!
           (flatpak-remote-by-name (string->symbol name))
           #:flatpakrepo
           (remote-descriptor-path
            (flatpak-remote-by-name (string->symbol name)))))
         (("gc")             (flatpak-gc))
         (_ (usage) (exit 1))))

(main (command-line))
