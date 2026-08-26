;;; 构建期在线数据机制（build-time online data）：把"应从某个 URL
;;; 取得、但不便/不应版本化为仓库内静态文件"的应用数据（语言模型、
;;; 大体积资源等上游只提供滚动地址的内容）声明为 file-like，与
;;; 仓库分发的配置文件同等级参与 home-files / xdg-config 等
;;; declarative 发布。
;;;
;;;   (online-file NAME URL #:key (sha256 #f) (refresh #f))
;;;
;;; 三种模式：
;;;   - sha256 给定（nix-base32 字符串）：与频道/官方包完全相同的
;;;     机制——fixed-output derivation（(guix download) url-fetch，
;;;     daemon 下载并校验、content-addressed、可用 substitute）；
;;;   - sha256 为 #f 且 refresh 为 #f（默认）：上游 URL 内容会变动
;;;     且无固定历史版本地址时使用。下载发生在 **lowering 期**
;;;     （guix 客户端进程内，有网络；daemon sandbox 无网络，普通
;;;     derivation 做不到），字节经 (guix store) binary-file 进
;;;     store（content-addressed），同时缓存在本地（见下）；
;;;   - sha256 为 #f 且 refresh 为 #t：与默认模式相同，但每次
;;;     lowering 都重新下载、跟随上游原地更新（binary-file
;;;     content-addressed：内容没变 store 路径不变，reconfigure
;;;     无副作用；内容变了自动生效）。下载失败（无网络/请求错误）
;;;     时若存在有效缓存则回退到缓存构建，否则透传错误（fail
;;;     fast）。
;;;
;;; cache 语义（sha256 = #f）：
;;;   默认目录 $XDG_CACHE_HOME/guixcfg/online-data/（或
;;;   ~/.cache/guixcfg/online-data/）。"有效缓存" = 文件存在且
;;;   .url sidecar 与声明的 URL 一致（不同 URL 的缓存绝不静默
;;;   复用）：
;;;     - 默认模式 cache-first：命中即复用，**仓库不追踪上游更新、
;;;       不重新下载**——上游该数据更新时，已缓存的应用数据不受
;;;       仓库干涉；显式刷新 = 删除 cache 后重新 build；
;;;     - refresh 模式每次都下载并重写 cache 与 sidecars（缓存
;;;       退化为"上次成功快照"），失败时回退到有效缓存。
;;;   每次实际下载写 .sha256 sidecar 记录当时内容的真实哈希，需要
;;;   固定时把它填进声明的 #:sha256 即切换到 fixed-output 模式。
;;;
;;; 不变量：
;;;   - 只在 lowering 期取网：模块加载、record 构造、测试求值绝不
;;;     触发下载（测试不得依赖公网——AGENT.md §4）。lowering 由
;;;     gexp compiler（本文件 online-file-compiler）在客户端进程
;;;     执行，因此 `guix home/system build|reconfigure` 会下载，
;;;     而 test-modules-load / record 级断言不会；
;;;   - 下载失败 fail fast（&http-get-error 透传），重试 = 重跑
;;;     同一命令（AGENT.md §1：网络问题一律重试，不发明替代方案）；
;;;     refresh 模式的唯一例外：有效缓存存在时回退缓存，失败原因
;;;     经 stderr 警告保留可见；
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
               #:use-module (srfi srfi-34)      ; guard（失败回退缓存）
               #:export (<online-file>
                         online-file
                         online-file?
                         online-file-name
                         online-file-url
                         online-file-sha256
                         online-file-refresh
                         %online-fetcher
                         %online-cache-directory
                         fetch-url-cached
                         fetch-url-refresh))

(define-record-type <online-file>
                    (%online-file name url sha256 refresh)
                    online-file?
                    (name    online-file-name)     ; string：store 内文件名 / cache 键
                    (url     online-file-url)      ; string：下载地址
                    (sha256  online-file-sha256)   ; #f 或 nix-base32 字符串
                    (refresh online-file-refresh)) ; boolean：每次 lowering 重新下载

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

(define (cache-path name)
  ;; cache 目录内 NAME 对应的文件路径。
  (string-append (%online-cache-directory) "/" name))

(define (cache-valid? name url)
  ;; 有效缓存判定：文件存在且 .url sidecar 与声明 URL 一致。
  ;; cache-first 命中与 refresh 回退共用同一判定——不同 URL 的
  ;; 缓存绝不静默复用。
  (let* ((cache (cache-path name))
         (url-sidecar (string-append cache ".url"))
         (cached-url (and (file-exists? url-sidecar)
                          (call-with-input-file url-sidecar
                                                get-string-all))))
    (and (file-exists? cache)
         (string? cached-url)
         (string=? (string-trim-right cached-url) url))))

(define (read-cached name)
  ;; 读缓存文件字节；调用方必须先确认 (cache-valid? name url)。
  (call-with-input-file (cache-path name) get-bytevector-all))

(define (write-cache! name url bytes)
  ;; 写缓存文件与 .url/.sha256 sidecar；.sha256 记录内容真实哈希，
  ;; 需要固定时可直接填进声明的 #:sha256（转 fixed-output 模式）。
  (let ((cache (cache-path name)))
    (mkdir-p (%online-cache-directory))
    (call-with-output-file cache
                           (lambda (port) (put-bytevector port bytes)))
    (call-with-output-file (string-append cache ".url")
                           (lambda (port) (display url port) (newline port)))
    (call-with-output-file (string-append cache ".sha256")
                           (lambda (port)
                             (format port "~a~%"
                                     (bytevector->nix-base32-string (sha256 bytes)))))))

(define (fetch-url-cached name url)
  "cache-first 取 URL 内容（名为 NAME），返回 bytevector。
cache 命中（文件存在且 .url sidecar 匹配）直接复用，不访问网络；
未命中时经 (%online-fetcher) 下载，写 cache + .url/.sha256
sidecar 后返回。"
  (if (cache-valid? name url)
    (read-cached name)
    (begin
     (format (current-error-port)
             "online-file: fetching ~a (no valid cache at ~a)~%"
             url (cache-path name))
     (let ((bytes ((%online-fetcher) url)))
       (write-cache! name url bytes)
       bytes))))

(define (error-detail err)
  ;; 提取失败原因用于 stderr 警告：&http-get-error 给出可读原因与
  ;; 状态码，其余 condition 打印对象表示（保持 English ASCII）。
  (if (http-get-error? err)
    (format #f "~a (code ~a)" (http-get-error-reason err)
            (http-get-error-code err))
    (object->string err)))

(define (fetch-url-refresh name url)
  "refresh 模式：总是经 (%online-fetcher) 重新下载（名为 NAME），
成功时重写 cache 与 sidecars 并返回字节；失败（无网络/请求错误）
时若存在有效缓存则回退缓存（stderr 警告，失败原因保留可见），
否则透传原错误（fail fast——AGENT.md §1：重试 = 重跑同一命令）。"
  (guard (err (#t
                (let ((cached (and (cache-valid? name url)
                                   (read-cached name))))
                  (if cached
                    (begin
                     (format (current-error-port)
                             "online-file: fetch failed (~a); using cached copy at ~a~%"
                             (error-detail err) (cache-path name))
                     cached)
                    (raise err)))))
         (let ((bytes ((%online-fetcher) url)))
           (write-cache! name url bytes)
           bytes)))

(define-gexp-compiler (online-file-compiler (file <online-file>)
                                            system target)
                      ;; lowering 期在客户端进程执行（有网络）。sha256 给定：fixed-
                      ;; output derivation（与频道相同的机制，daemon 下载并校验）；
                      ;; 为 #f：refresh #t 时每次重新下载（失败回退有效缓存），否则
                      ;; cache-first，然后 binary-file 进 store。
                      (let ((name (online-file-name file))
                            (url (online-file-url file))
                            (hash (online-file-sha256 file))
                            (refresh (online-file-refresh file)))
                        (if hash
                          (url-fetch url 'sha256 (nix-base32-string->bytevector hash) name
                                     #:system system)
                          (binary-file name (if refresh
                                              (fetch-url-refresh name url)
                                              (fetch-url-cached name url))))))

(define* (online-file name url #:key (sha256 #f) (refresh #f))
         "声明一个构建期在线数据 file-like：NAME 是 store 内文件名，URL
是下载地址。SHA256 为 nix-base32 字符串时走 fixed-output
derivation（与频道机制相同，daemon 下载并校验）；为 #f 时默认走
cache-first 本地缓存（仓库不追踪上游更新；刷新 = 删除 cache 后
重建），REFRESH 为 #t 时每次 lowering 重新下载、跟随上游更新，
失败（无网络/请求错误）时回退有效缓存。REFRESH 与 SHA256 互斥
（fixed-output 的哈希本身就是 pin）。可用于 home-files /
home-xdg-configuration-files 等任何接受 file-like 的位置。
只在 lowering 期取网，构造与求值不触发下载。"
         (unless (or (not sha256) (string? sha256))
           (error "online-file: sha256 must be #f or a nix-base32 string"
                  name sha256))
         (when (and sha256 refresh)
           (error "online-file: #:refresh is meaningless with a pinned #:sha256"
                  name url))
         (%online-file name url sha256 refresh))
