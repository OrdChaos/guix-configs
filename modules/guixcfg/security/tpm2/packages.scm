;;; tpm2 工具链兼容包：tpm2-tss 3.0.3 与 openssl 3.5 的 HMAC 不兼容
;;; （EVP_PKEY_new_mac_key 失败 0x70001，实测影响 tpm2_createprimary 等
;;; 全部 TPM 操作，initrd 解锁与 enrollment 都会崩），用 openssl-3.0
;;; 重建 tpm2-tss/tpm2-tools。这是 T3 实测发现的 TPM 层 blocker。

(define-module (guixcfg security tpm2 packages)
               #:use-module (gnu packages tls)       ; openssl-3.0
               #:use-module (gnu packages pkg-config) ; pkg-config
               #:use-module (gnu packages linux)     ; util-linux（libuuid）
               #:use-module (gnu packages admin)     ; shadow（addgroup）
               #:use-module (gnu packages hardware)  ; tpm2-tss、tpm2-tools
               #:use-module (guix packages)          ; modify-inputs
               #:use-module (guix download)        ; url-fetch
               #:use-module (guix build-system meson) ; meson-build-system
               #:use-module (guix build-system gnu)   ; gnu-build-system
               #:use-module (guix gexp)
               #:export (tpm2-tss-compat
                         tpm2-tools-compat))

;; tpm2-tss 3.0.3 的 esys HMAC 与 openssl 3.x 不兼容（EVP_PKEY_new_mac_key
;; 失败 0x70001，openssl 3.0 与 3.5 均实测崩溃）；4.x 改用 EVP_MAC API 修复。
;; 4.1.3 为当前稳定版，与宿主（Arch tpm2-tools 5.7 + tpm2-tss 4.1.3，
;; T2 集成环境）对齐。注：T3 曾怀疑 4.0.1 的 keyedhash 模板 marshalling
;; 导致 TPM2_Create 报 0x2E1；实测根因是 sealed object attrs 位定义
;; （见 tpm2-tools.scm 的 tpm2-create-sealed!），与 tss 版本无关。
;; 4.1.3 保留为维护性升级（安全/正确性修复）。
(define tpm2-tss-compat
  (package
   (inherit tpm2-tss)
   (name "tpm2-tss-compat")
   (version "4.1.3")
   (source
    (origin
     (method url-fetch)
     (uri (string-append
           "https://github.com/tpm2-software/tpm2-tss/releases/download/"
           version "/tpm2-tss-" version ".tar.gz"))
     (sha256 (base32 "1s1v1nk3f9rkpxcwanz8rf9hrvma869dhwn83xfk0y5b0015iw9p"))))
   (build-system gnu-build-system)
   ;; fapi/policy 需要 libuuid（util-linux 的 libuuid 未单独打包）；
   ;; 本项目只用 esys/sys/tcti，禁用之。
   (arguments '(#:configure-flags '("--disable-fapi" "--disable-policy")))
   (native-inputs (modify-inputs (package-native-inputs tpm2-tss)
                                 (prepend pkg-config shadow)))
   (inputs (modify-inputs (package-inputs tpm2-tss)
                          (replace "openssl" openssl-3.0)))))

(define tpm2-tools-compat
  (package
   (inherit tpm2-tools)
   (name "tpm2-tools-compat")
   ;; tpm2-tools 自身的 openssl 依赖也必须换：其 RUNPATH 里的
   ;; openssl-3.5 会污染 libcrypto.so.3 的解析（实测 esys HMAC 仍崩）。
   (inputs (modify-inputs (package-inputs tpm2-tools)
                          (replace "openssl" openssl-3.0)))
   (native-inputs (modify-inputs (package-native-inputs tpm2-tools)
                                 (replace "tpm2-tss" tpm2-tss-compat)
                                 (replace "openssl" openssl-3.0)))))
