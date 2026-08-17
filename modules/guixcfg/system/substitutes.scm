;;; Nonguix substitute trust policy（唯一 authoritative source；
;;; docs/architecture/overview.md（Nonguix integration））。
;;;
;;; 概念分层（channel != substitute）：
;;;   - channel policy：evaluator 从哪得到 Nonguix Scheme/package 定义
;;;     ——channels.lock.scm（pinned revision，本模块不碰）；
;;;   - substitute trust policy：guix-daemon 去哪找 binary substitutes、
;;;     信任哪些 public signing keys——本模块（steady-state declarative）；
;;;   - bootstrap policy：当前 old daemon / installer daemon 在目标
;;;     generation 的 daemon 配置生效前如何获得 Nonguix substitute
;;;     capability——docs/operations/installation.md（Nonguix
;;;     substitute bootstrap）。
;;;
;;; 不变量：
;;;   - 官方 Nonguix URL 与 public signing key 只有一份定义（本模块 +
;;;     modules/guixcfg/system/nonguix-key.pub 同一 canonical key 文件）；
;;;   - 通过 guix-service-type 的 additive extension 追加（guix-extension
;;;     的 extend 是 append 语义：Guix 默认 substitute URLs/authorized
;;;     keys 自然保留，不被覆盖）；
;;;   - public key 是 declarative trust material——可以进 /gnu/store，
;;;     不需要 age/TPM/LUKS/Secure Boot；不进 /persist；
;;;   - 不添加任何第三方 proxy/cache（只信任 pinned Nonguix 官方
;;;     substitute service）。

(define-module (guixcfg system substitutes)
               #:use-module (gnu services)         ; simple-service
               #:use-module (gnu services base)    ; guix-service-type、guix-extension
               #:use-module (guix gexp)            ; local-file
               #:use-module (guix store)           ; %default-substitute-urls
               #:export (%nonguix-substitute-url
                         %nonguix-substitute-key-file
                         %transition-substitute-urls
                         nonguix-substitute-service))

;; 官方 Nonguix substitute URL（pinned Nonguix README：
;; https://substitutes.nonguix.org，无尾斜杠）。
(define %nonguix-substitute-url "https://substitutes.nonguix.org")

;; 官方 Nonguix signing public key 文件（canonical 副本；内容来自
;; pinned Nonguix README 的 signing-key.pub）。local-file 的相对
;; 路径相对本文件所在目录（guix gexp 语义），因此只写 basename。
(define %nonguix-substitute-key-file
  (local-file "nonguix-key.pub" "nonguix.pub"))

;; 首次 transition / 尚未运行含 nonguix-substitute-service 的新
;; generation 前，当前 daemon 的 substitute-urls 配置不含 Nonguix。
;; 这段 URLs 是显式 bootstrap（与 CLI 的 --substitute-urls 等价）：
;; 官方 Guix 默认 + 官方 Nonguix。测试/脚本经
;; (set-build-options %store #:substitute-urls %transition-substitute-urls)
;; 传入，让 build 请求命中 Nonguix substitute（而不是本地编译 kernel）。
(define %transition-substitute-urls
  (append (list %nonguix-substitute-url) %default-substitute-urls))

;; 给既有 guix-daemon service 追加 Nonguix substitute capability。
;; additive extension：guix-extension 的 extend 是 append 语义——
;; Guix 默认 substitute URLs（bordeaux/ci）与默认 authorized keys
;; 自然保留；VM/laptop/install 复用本 service，不 per-host 重复。
(define nonguix-substitute-service
  (simple-service 'nonguix-substitutes guix-service-type
                  (guix-extension
                   (authorized-keys (list %nonguix-substitute-key-file))
                   (substitute-urls (list %nonguix-substitute-url)))))
