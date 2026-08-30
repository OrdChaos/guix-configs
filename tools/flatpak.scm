;;; Flatpak 显式运维入口（tooling plane——仓库内 CLI，唯一允许联网
;;; 的地方；docs/architecture/flatpak.md（operations））。
;;;
;;; 用法（从仓库根目录）：
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- sync
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- status [--refresh]
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- update-runtimes
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- remove <logical-name>
;;;   guix time-machine -C channels.lock.scm -- repl tools/flatpak.scm -- gc
;;;
;;; 语义（reconcile.scm 头部）：sync 只增不删；status 默认离线；
;;; update 显式 ref 列表；remove ≠ purge；gc 显式维护。
;;; 一切操作 --user scope。reconfigure/boot/login 与网络零耦合。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg flatpak reconcile)
             (ice-9 format)
             (ice-9 match))

(define (usage)
  (format #t "Usage:
  flatpak sync                  ensure declared remotes and selected apps (add-only)
  flatpak status [--refresh]    show declared/installed state (offline; --refresh queries remotes)
  flatpak update                update unpinned selected+installed apps (explicit refs only)
  flatpak update-runtimes       update installed runtimes (explicit refs only)
  flatpak remove <logical-name> uninstall one catalog application (user data preserved)
  flatpak gc                    maintenance: remove unused runtimes + repair installation~%"))

(define (main args)
  ;; install/export 时 flatpak 用 FLATPAK_BINARY 写绝对 Exec
  ;; （DBusActivatable desktop entries 在 CWD=/、无 PATH 的
  ;; activation 环境下也能启动）。
  (setenv "FLATPAK_BINARY" (flatpak-binary))
  (match (cdr args)
         (("sync")           (flatpak-sync))
         (("status")         (flatpak-status))
         (("status" "--refresh") (flatpak-status #:refresh? #t))
         (("update")         (flatpak-update))
         (("update-runtimes") (flatpak-update-runtimes))
         (("remove" name)    (flatpak-remove (string->symbol name)))
         (("gc")             (flatpak-gc))
         (_ (usage) (exit 1))))

(main (command-line))
