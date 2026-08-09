;;; 存储模型：GPT / LUKS2 / Btrfs 布局的纯数据结构与固定事实。
;;; 本模块只描述“磁盘应该是什么样”，不执行任何磁盘操作（阶段 2 才执行）。
;;; 对应 docs/storage.md 第 10–13、20 章。
;;;
;;; 记录类型一律使用 (guix records) 的 define-record-type*（项目约定）：
;;; 具名字段构造、(default ...)、(inherit ...) 都由它提供。

(define-module (guixcfg storage model)
               #:use-module (guix records)  ; define-record-type*
               #:use-module (srfi srfi-13)  ; 字符串工具（string-prefix? 等）
               #:export (;; 单位换算
                         mib gib
                         ;; 固定命名事实（docs/storage.md 第 11、19 章）
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
;;; 固定命名事实（docs/storage.md 第 20.1 节：直接写进实现，不做配置项）。
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

;; ESP 大小策略范围（docs/storage.md 第 11 章：2–4 GiB）。
(define %esp-min-size (gib 2))
(define %esp-max-size (gib 4))

;;; ────────────────────────────────────────────────────────────
;;; Host policy：真正因机器而不同的内容（docs/storage.md 第 20.2 节）。
;;;
;;; define-record-type* 的形式是：
;;;   (define-record-type* <类型名> 具名构造器 位置构造器 谓词?
;;;     (字段 访问器 (可选修饰如 default)))
;;; 构造时写字段名，顺序随意：(host-storage-policy (name 'vm) (esp-size ...))。

;; Host policy 的“类型”定义在本模块（它是存储模型的一部分），
;; 但每台机器的 policy“实例”定义在各自的 host 模块中
;; （(guixcfg hosts vm) / (guixcfg hosts laptop)），
;; 因为 host 才是最终组装点（docs/project-definition.md 第 21 章），
;; 共享模块不反向依赖 host（原则 6）。

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
;;; 持久子卷（docs/storage.md 第 12 章：固定项目事实）。

(define-record-type* <subvolume>
                     subvolume make-subvolume
                     subvolume?
                     (name        subvolume-name)         ; Btrfs 子卷名，必须带 @persist- 前缀
                     (mount-point subvolume-mount-point)  ; 挂载点
                     (options     subvolume-options       ; 挂载选项列表，如 '("compress=zstd")
                                  (default '())))

(define %swap-subvolume-name "@persist-swap")   ; swapfile 所在子卷（第 13.5 节）

;; 固定的 9 个持久子卷。顺序即创建顺序。
;; 除 /gnu/store、/var/guix 和 /boot 外，挂载点一律位于 /persist（第 10.2 节）。
(define %persist-subvolumes
  (list (subvolume (name "@persist-gnu-store")
                   (mount-point "/gnu/store"))
        (subvolume (name "@persist-var-guix")
                   (mount-point "/var/guix"))
        ;; /boot 必须在永不替换的持久子卷上：GRUB 核心镜像的 prefix 是
        ;; grub-install 探测 /boot 当时位置后写死的，若 /boot 住在
        ;; @root-N 上，每次新建 root generation 后 GRUB 都找不到
        ;; normal.mod（掉 rescue）。
        (subvolume (name "@persist-boot")
                   (mount-point "/boot"))
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
  "NAME 是否符合持久子卷命名规则（docs/storage.md 第 10.1 节）。"
  (string-prefix? "@persist-" name))

;;; ────────────────────────────────────────────────────────────
;;; Root generation 命名（docs/storage.md 第 17.1 节）。
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
