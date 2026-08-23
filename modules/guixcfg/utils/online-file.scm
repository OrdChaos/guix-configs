;;; 构建期在线数据机制（build-time online data）：把"应从某个 URL
;;; 取得、但不便/不应版本化为仓库内静态文件"的应用数据（语言模型、
;;; 大体积资源等上游只提供滚动地址的内容）声明为 file-like，与
;;; 仓库分发的配置文件同等级参与 home-files / xdg-config 等
;;; declarative 发布。
;;;
;;;   (online-file NAME URL #:key (sha256 #f))
;;;
;;; 两种模式：
;;;   - sha256 给定（nix-base32 字符串）：与频道/官方包完全相同的
;;;     机制——fixed-output derivation（(guix download) url-fetch，
;;;     daemon 下载并校验、content-addressed、可用 substitute）；
;;;   - sha256 为 #f：上游 URL 内容会变动且无固定历史版本地址时
;;;     使用。下载发生在 **lowering 期**（guix 客户端进程内，有
;;;     网络；daemon sandbox 无网络，普通 derivation 做不到），
;;;     字节经 (guix store) binary-file 进 store（content-
;;;     addressed），同时缓存在本地（见下）。
;;;
;;; cache 语义（sha256 = #f；cache-first）：
;;;   默认目录 $XDG_CACHE_HOME/guixcfg/online-data/（或
;;;   ~/.cache/guixcfg/online-data/）。命中（文件存在且 .url
;;;   sidecar 与声明的 URL 一致）即复用，**仓库不追踪上游更新、
;;;   不重新下载**——上游该数据更新时，已缓存的应用数据不受仓库
;;;   干涉；显式刷新 = 删除 cache 后重新 build。每次实际下载写
;;;   .sha256 sidecar 记录当时内容的真实哈希，需要固定时把它填进
;;;   声明的 #:sha256 即切换到 fixed-output 模式。
;;;
;;; 不变量：
;;;   - 只在 lowering 期取网：模块加载、record 构造、测试求值绝不
;;;     触发下载（测试不得依赖公网——AGENT.md §4）。lowering 由
;;;     gexp compiler（本文件 online-file-compiler）在客户端进程
;;;     执行，因此 `guix home/system build|reconfigure` 会下载，
;;;     而 test-modules-load / record 级断言不会；
;;;   - 下载失败 fail fast（&http-get-error 透传），重试 = 重跑
;;;     同一命令（AGENT.md §1：网络问题一律重试，不发明替代方案）；
;;;   - 输出消息保持 English printable ASCII（AGENT.md §11）；
;;;   - 测试经 %online-fetcher / %online-cache-directory 参数注入
;;;     假 fetcher 与临时目录，不访问网络。

(define-module (guixcfg utils online-file)
               #:use-module (guix gexp)         ; define-gexp-compiler
               #:use-module (guix download)     ; url-fetch（fixed-output）
               #:use-module (guix store)        ; binary-file
               #:use-module (guix base32)       ; nix-base32-string->bytevector 等
               #:use-module (guix http-client)  ; http-fetch（跟随重定向）
               #:use-module (guix build utils)  ; mkdir-p
               #:use-module (gcrypt hash)       ; sha256
               #:use-module (rnrs io ports)     ; get-bytevector-all、put-bytevector
               #:use-module (srfi srfi-9)       ; define-record-type
               #:use-module (srfi srfi-13)      ; string-trim-right
               #:export (<online-file>
                         online-file
                         online-file?
                         online-file-name
                         online-file-url
                         online-file-sha256
                         %online-fetcher
                         %online-cache-directory
                         fetch-url-cached))

(define-record-type <online-file>
  (%online-file name url sha256)
  online-file?
  (name   online-file-name)     ; string：store 内文件名 / cache 键
  (url    online-file-url)      ; string：下载地址
  (sha256 online-file-sha256))  ; #f 或 nix-base32 字符串

(define %online-cache-directory
  ;; 下载缓存目录（参数化以便测试注入临时目录）。
  (make-parameter
   (string-append (or (getenv "XDG_CACHE_HOME")
                      (string-append (getenv "HOME") "/.cache"))
                  "/guixcfg/online-data")))

(define (default-online-fetcher url)
  "下载 URL 的全部字节，返回 bytevector（http-fetch 自动跟随
重定向；失败抛 &http-get-error——fail fast，调用方重跑即重试）。"
  (call-with-port (http-fetch url) get-bytevector-all))

(define %online-fetcher
  ;; 实际执行下载的 thunk（参数化以便测试注入假 fetcher）。
  (make-parameter default-online-fetcher))

(define (fetch-url-cached name url)
  "cache-first 取 URL 内容（名为 NAME），返回 bytevector。
cache 命中（文件存在且 .url sidecar 匹配）直接复用，不访问网络；
未命中时经 (%online-fetcher) 下载，写 cache + .url/.sha256
sidecar 后返回。"
  (let* ((dir (%online-cache-directory))
         (cache (string-append dir "/" name))
         (url-sidecar (string-append cache ".url"))
         (cached-url (and (file-exists? url-sidecar)
                          (call-with-input-file url-sidecar
                            get-string-all))))
    (if (and (file-exists? cache)
             (string? cached-url)
             (string=? (string-trim-right cached-url) url))
        (call-with-input-file cache get-bytevector-all)
        (begin
          (format (current-error-port)
                  "online-file: fetching ~a (no valid cache at ~a)~%"
                  url cache)
          (let ((bytes ((%online-fetcher) url)))
            (mkdir-p dir)
            (call-with-output-file cache
              (lambda (port) (put-bytevector port bytes)))
            (call-with-output-file url-sidecar
              (lambda (port) (display url port) (newline port)))
            (call-with-output-file (string-append cache ".sha256")
              (lambda (port)
                (format port "~a~%"
                        (bytevector->nix-base32-string (sha256 bytes)))))
            bytes)))))

(define-gexp-compiler (online-file-compiler (file <online-file>)
                                            system target)
  ;; lowering 期在客户端进程执行（有网络）。sha256 给定：fixed-
  ;; output derivation（与频道相同的机制，daemon 下载并校验）；
  ;; 为 #f：本地 cache-first 下载后 binary-file 进 store。
  (let ((name (online-file-name file))
        (url (online-file-url file))
        (hash (online-file-sha256 file)))
    (if hash
        (url-fetch url 'sha256 (nix-base32-string->bytevector hash) name
                   #:system system)
        (binary-file name (fetch-url-cached name url)))))

(define* (online-file name url #:key (sha256 #f))
  "声明一个构建期在线数据 file-like：NAME 是 store 内文件名，URL
是下载地址；SHA256 为 nix-base32 字符串时走 fixed-output
derivation（与频道机制相同），为 #f 时走本地 cache-first 下载
（仓库不追踪上游更新；刷新 = 删除 cache 后重建）。可用于
home-files / home-xdg-configuration-files 等任何接受 file-like
的位置。只在 lowering 期取网，构造与求值不触发下载。"
  (unless (or (not sha256) (string? sha256))
    (error "online-file: sha256 must be #f or a nix-base32 string"
           name sha256))
  (%online-file name url sha256))
