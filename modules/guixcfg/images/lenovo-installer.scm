;;; Lenovo Legion Y7000P 离线安装 ISO 入口（docs/operations/offline-iso.md）。
;;;
;;; 该文件同时是 Guix system image 配置文件：`guix system image` 取
;;; 最后一个顶层表达式的值。构建命令必须经 pinned channels.lock.scm
;;; 运行（见 offline-iso.md），使 current-profile 精确对应当前锁；
;;; helper 会把该 profile 作为 GC root 并预置到 installer inferior
;;; cache，保证安装期与 firstboot 的 guix time-machine 离线 cache hit。
;;;
;;; 目标 OS 在构建 ISO 时需要一组 machine facts。fresh-install ISO 只
;;; 用它们预取 heavy closure；真正 install 时 blue install 会按目标盘
;;; 写入真实 LUKS UUID，system init 在同一 ISO store 上离线重建小型
;;; system derivation（包闭包已全部在盘内）。

(define-module (guixcfg images lenovo-installer)
               #:use-module (gnu packages)      ; specification->package
               #:use-module (guix channels)    ; channel、channel-commit
               #:use-module (guix describe)    ; current-profile
               #:use-module (guixcfg apps blue definition) ; blue-compatible
               #:use-module (guixcfg hosts lenovo-legion-y7000p)
               #:use-module (guixcfg images offline)
               #:use-module (guixcfg utils repository-source)
               #:use-module (srfi srfi-1)
               #:export (%lenovo-offline-installer-os))

(define %locked-channels
  (eval (call-with-input-file (string-append (repository-root)
                                             "/channels.lock.scm")
                               read)
        (current-module)))

(define %channel-profile-cache-key
  (channel-profile-cache-key %locked-channels))

(define %pinned-channel-profile
  (let ((profile (current-profile)))
    (unless profile
      (error "lenovo-installer.scm must be evaluated by 'guix time-machine'"))
    ;; time-machine 的 inferior cache 项是指向 store profile 的符号
    ;; 链接；canonicalize 后把真实 store item 放入 ISO closure。
    (canonicalize-path profile)))

(define %installer-extra-packages
  ;; blue install / firstboot 需要的 installer-only 工具。qemu 刻意不
  ;; 包含（它只是宿主 VM 测试工具）；Flatpak 工具链不属于本 ISO 契约。
  (list blue-compatible
        (specification->package "git")
        (specification->package "ukify")
        (specification->package "openssl")
        (specification->package "efitools")
        (specification->package "sbsigntools")))

(define %lenovo-offline-installer-os
  (offline-installation-os %lenovo-legion-y7000p-os
                           #:channel-profile %pinned-channel-profile
                           #:repository (repository-snapshot)
                           #:cache-key %channel-profile-cache-key
                           #:extra-packages %installer-extra-packages))

;; guix system image 配置入口：加载本文件时取最后一个表达式。
%lenovo-offline-installer-os
