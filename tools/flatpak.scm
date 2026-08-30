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
;;; trust 模型：bootstrap 直接使用 registry 声明的官方 descriptor
;;; URL（flatpak remote-add --from 自行下载并导入当前官方 GPGKey）；
;;; 本入口不 vendor key、不生成 descriptor、不维护指纹/过期日期。

;; guix repl 不提供 -L，这里显式把 modules/ 加入 load path（从仓库根目录运行）。
(add-to-load-path (string-append (getcwd) "/modules"))

(use-modules (guixcfg flatpak reconcile)
             (ice-9 format)
             (ice-9 match))

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
         (("sync")           (flatpak-sync))
         (("status")         (flatpak-status))
         (("status" "--refresh") (flatpak-status #:refresh? #t))
         (("update")         (flatpak-update))
         (("update-runtimes") (flatpak-update-runtimes))
         (("remove" name)    (flatpak-remove (string->symbol name)))
         (("remote-replace" name)
          (flatpak-replace-remote! (flatpak-remote-by-name
                                    (string->symbol name))))
         (("gc")             (flatpak-gc))
         (_ (usage) (exit 1))))

(main (command-line))
