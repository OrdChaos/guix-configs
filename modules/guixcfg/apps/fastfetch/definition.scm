;;; fastfetch
;;;
;;; 用 fastfetch-minimal 而非 fastfetch（2026-10-04）：完整版的 inputs
;;; 含 zfs——仅为 ZFS pool 探测链接 libzfs，而 guix 的 zfs 包用
;;; linux-module-build-system + linux-libre-lts 编译内核模块，把整个
;;; linux-libre 拖进 build graph（运行期闭包实测无 linux-libre；
;;; 且 zfs #:substitutable? #f 只能本地编译）。本机用 btrfs，ZFS
;;; 探测无意义。

(define-module (guixcfg apps fastfetch definition)
  #:use-module (gnu packages admin) ;fastfetch-minimal
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%fastfetch))

(define %fastfetch
  (application (name 'fastfetch)
               (home-packages (list fastfetch-minimal))))
