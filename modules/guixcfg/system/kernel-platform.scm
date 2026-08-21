;;; Kernel platform 的唯一 authoritative 定义（M1：Linux-libre →
;;; Nonguix standard Linux，docs/architecture/boot.md（Kernel platform））。
;;;
;;; one fact, one authoritative definition：
;;;   - %kernel：系统 runtime kernel（VM/laptop 都消费它；host 不得各自
;;;     定义 kernel，linux-libre 不再被任何 host 选中）；
;;;   - %kernel-firmware：declarative firmware（不经 installer 手工复制、
;;;     不从 /persist 注入、不用 runtime shell hack）；
;;;   - %kernel-microcode-packages：Intel microcode（实机为 Intel CPU；
;;;     AMD 不混入 common base——host fact 与 common policy 区分）；
;;;   - microcode-ephemeral-initrd：microcode 与 custom initrd 的
;;;     composition（microcode cpio 拼接在 custom initrd 之前，
;;;     combined-initrd；custom initrd 仍是 authoritative payload，
;;;     绝不替换——docs/architecture/boot.md（Microcode））。
;;;
;;; API 以 channels.lock.scm 锁定的 Nonguix revision（653504e）为准：
;;;   - (nongnu packages linux)：linux（= linux-7.1）、linux-firmware、
;;;     intel-microcode；
;;;   - (nongnu system linux-initrd)：microcode-initrd——接受 #:initrd
;;;     参数（我们的 initrd builder），#:allow-other-keys 把框架的
;;;     linux/linux-modules/mapped-devices/keyboard-layout 透传给
;;;     custom initrd。

(define-module (guixcfg system kernel-platform)
               #:use-module (nongnu packages linux)        ; linux、linux-firmware、intel-microcode
               #:use-module (nongnu system linux-initrd)   ; microcode-initrd
               #:use-module (guixcfg boot initrd)          ; ephemeral-root-initrd
               #:export (%kernel
                         %kernel-firmware
                         %kernel-microcode-packages
                         microcode-ephemeral-initrd))

;; 系统 runtime kernel：Nonguix standard Linux（pinned revision 的
;; `linux' = linux-7.1，corrupt-linux 包装——含非自由 blob 的
;; unmodified upstream kernel）。这是唯一权威 kernel 定义。
(define %kernel linux)

;; 完整 linux-firmware（generic firmware ecosystem；NVIDIA proprietary
;; driver 属于后续 graphics phase，不在此处）。
(define %kernel-firmware linux-firmware)

;; Intel CPU microcode（实机 Intel；AMD microcode 不加入 common base）。
(define %kernel-microcode-packages (list intel-microcode))

(define* (microcode-ephemeral-initrd file-systems . rest)
         "<operating-system> 的 initrd 构建器：microcode-initrd 把 Intel
microcode cpio 拼接在 ephemeral-root-initrd 之前（combined-initrd，
kernel 从单文件加载多个 initrd archive）。框架传入的 linux/
linux-modules/mapped-devices/keyboard-layout 经 REST 透传给 custom
initrd——custom initrd 仍是 authoritative payload implementation。
调用约定由 operating-system-initrd-file 决定。"
         (apply microcode-initrd file-systems
           #:initrd ephemeral-root-initrd
           #:microcode-packages %kernel-microcode-packages
           rest))
