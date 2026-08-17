;;; 存储模型：GPT / LUKS2 / Btrfs 布局的纯数据结构与固定事实。
;;; 本模块只描述“磁盘应该是什么样”，不执行任何磁盘操作（阶段 2 才执行）。
;;; 对应 docs/architecture/storage.md。
;;;
;;; 记录类型一律使用 (guix records) 的 define-record-type*（项目约定）：
;;; 具名字段构造、(default ...)、(inherit ...) 都由它提供。

(define-module (guixcfg storage model)
               #:use-module (guix records)  ; define-record-type*
               #:use-module (srfi srfi-13)  ; 字符串工具（string-prefix? 等）
               #:export (;; 单位换算
                         mib gib
                         ;; 固定命名事实（docs/architecture/storage.md（固定命名事实））
                         %esp-partlabel %system-partlabel
                         %esp-gpt-typecode %system-gpt-typecode
                         %esp-filesystem-label %btrfs-filesystem-label
                         %luks-label %luks-mapper-name
                         %esp-min-size %esp-max-size
                         ;; host policy
                         <host-storage-policy>
                         host-storage-policy make-host-storage-policy host-storage-policy?
                         host-storage-policy-name
                         host-storage-policy-esp-size
                         host-storage-policy-min-disk-size
                         host-storage-policy-swapfile-size
                         host-storage-policy-keep-root-generations
                         host-storage-policy-expected-disk-by-id
                         ;; 持久子卷
                         <subvolume>
                         subvolume make-subvolume subvolume?
                         subvolume-name subvolume-mount-point subvolume-options
                         subvolume-mount-at-install?
                         %persist-subvolumes
                         persist-subvolume-name?
                         ;; root generation
                         %root-installing-name %root-template-name
                         %swap-subvolume-name
                         root-generation-name parse-root-generation))

;;; ────────────────────────────────────────────────────────────
;;; 单位：全部尺寸统一用字节数（整数）表示，避免单位混乱。

(define (mib n) (* n 1024 1024))
(define (gib n) (* n 1024 1024 1024))

;;; ────────────────────────────────────────────────────────────
;;; 固定命名事实（docs/architecture/storage.md（固定命名事实）：直接写进实现，不做配置项）。
;;; 启动和挂载优先使用这些语义名称，而不是安装时生成的 UUID（第 19 章）。

(define %esp-partlabel "esp")            ; GPT PARTLABEL：EFI 系统分区
(define %system-partlabel "system")      ; GPT PARTLABEL：加密系统分区

;; GPT 分区类型码（sgdisk）：EF00 = EFI System，8309 = Linux LUKS。
(define %esp-gpt-typecode "EF00")
(define %system-gpt-typecode "8309")

(define %esp-filesystem-label "ESP")     ; VFAT 卷标（惯例大写）
(define %btrfs-filesystem-label "rootfs"); Btrfs 文件系统标签
(define %luks-label "cryptroot")         ; LUKS2 头标签
(define %luks-mapper-name "cryptroot")   ; device-mapper 名：/dev/mapper/cryptroot

;; ESP 大小策略范围（docs/architecture/storage.md（磁盘布局）：2–4 GiB）。
(define %esp-min-size (gib 2))
(define %esp-max-size (gib 4))

;;; ────────────────────────────────────────────────────────────
;;; Host policy：真正因机器而不同的内容（docs/architecture/storage.md（持久子卷））。
;;;
;;; define-record-type* 的形式是：
;;;   (define-record-type* <类型名> 具名构造器 位置构造器 谓词?
;;;     (字段 访问器 (可选修饰如 default)))
;;; 构造时写字段名，顺序随意：(host-storage-policy (name 'vm) (esp-size ...))。

;; Host policy 的“类型”定义在本模块（它是存储模型的一部分）；具体实例
;; 集中定义在 (guixcfg storage policies)。这样早期 disk-install 只加载纯存储
;; 依赖，不会为了取得 policy 反向加载完整 host OS/UKI/channel 图。host 模块
;; 仍可重新导出对应 policy 作为最终组装点的兼容接口。

(define-record-type* <host-storage-policy>
                     host-storage-policy make-host-storage-policy
                     host-storage-policy?
                     (name                  host-storage-policy-name)                  ; 符号：vm / laptop
                     (esp-size              host-storage-policy-esp-size)              ; 字节，须在 2–4 GiB
                     (min-disk-size         host-storage-policy-min-disk-size)         ; 字节，目标盘容量下限
                     (swapfile-size         host-storage-policy-swapfile-size)         ; 字节
                     (keep-root-generations host-storage-policy-keep-root-generations) ; 保留的旧 root 数
                     (expected-disk-by-id   host-storage-policy-expected-disk-by-id    ; /dev/disk/by-id/... 或 #f
                                            (default #f)))

;;; ────────────────────────────────────────────────────────────
;;; 持久子卷（docs/architecture/storage.md（持久子卷）：固定项目事实）。

(define-record-type* <subvolume>
                     subvolume make-subvolume
                     subvolume?
                     (name        subvolume-name)         ; Btrfs 子卷名，必须带 @persist- 前缀
                     (mount-point subvolume-mount-point)  ; 挂载点
                     (options     subvolume-options       ; 挂载选项列表，如 '("compress=zstd")
                                  (default '()))
                     ;; 安装期（init 之前）是否挂载到目标。
                     ;; @persist-var-guix 必须为 #f：guix system init 会
                     ;; delete-file-recursively 目标的 /var/guix，挂载点
                     ;; 删不掉（EBUSY）导致注册不可靠；改为 init 后在
                     ;; commit-root 里把内容收进子卷（见 storage/commit.scm）。
                     (mount-at-install? subvolume-mount-at-install?
                                        (default #t)))

(define %swap-subvolume-name "@persist-swap")   ; swapfile 所在子卷（第 13.5 节）

;; 固定的 8 个持久子卷。顺序即创建顺序。
;; 除 /gnu/store 和 /var/guix 外，挂载点一律位于 /persist（第 10.2 节）。
;; 注意 /boot 不在此列：它是 root generation 上的普通目录——
;; bootloader 状态（UKI/Limine）全部在 ESP 上，不依赖 /boot 持久化。
(define %persist-subvolumes
  (list (subvolume (name "@persist-gnu-store")
                   (mount-point "/gnu/store"))
        (subvolume (name "@persist-var-guix")
                   (mount-point "/var/guix")
                   (mount-at-install? #f))   ; init 后再收养，见 record 注释
        (subvolume (name "@persist-system")
                   (mount-point "/persist/system"))
        (subvolume (name "@persist-data-app")
                   (mount-point "/persist/data-app")
                   (options '("compress=zstd")))
        (subvolume (name "@persist-data-home")
                   (mount-point "/persist/data-home")
                   (options '("compress=zstd")))
        (subvolume (name "@persist-data-nobackup")
                   (mount-point "/persist/data-nobackup")
                   (options '("compress=zstd")))
        ;; @persist-swap 专用于隔离 swapfile 约束：NOCOW、不压缩、不做快照（第 13.5 节）。
        (subvolume (name %swap-subvolume-name)
                   (mount-point "/persist/swap"))
        (subvolume (name "@persist-snapshots")
                   (mount-point "/persist/snapshots"))))

(define (persist-subvolume-name? name)
  "NAME 是否符合持久子卷命名规则（docs/architecture/storage.md）。"
  (string-prefix? "@persist-" name))

;;; ────────────────────────────────────────────────────────────
;;; Root generation 命名（docs/architecture/storage.md）。
;;; 不带 @persist- 前缀：它们是可替换的 root，不是长期状态（第 10.3 节）。

(define %root-installing-name "@root-installing")  ; 安装期工作 root
(define %root-template-name    "@root-template")   ; 只读模板

(define (root-generation-name n)
  "第 N 个 root generation 的子卷名：@root-N（N 为非负整数，不补零）。"
  (string-append "@root-" (number->string n)))

(define (parse-root-generation name)
  "若 NAME 是合法的 @root-N，返回整数 N；否则返回 #f。
拒绝补零（@root-01）和非数字后缀（@root-template）。"
  (let ((prefix "@root-"))
    (if (string-prefix? prefix name)
      (let ((digits (string-drop name (string-length prefix))))
        (and (not (string-null? digits))
             (string-every char-numeric? digits)
             (or (string=? digits "0")
                 (not (char=? (string-ref digits 0) #\0)))
             (string->number digits)))
      #f)))
