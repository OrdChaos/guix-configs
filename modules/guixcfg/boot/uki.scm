;;; UKI 部署核心（deploy-core）：把 Boot Plan 部署成 ESP 上的
;;; Limine 菜单 + UKI。本模块【不依赖】Guix 的 <bootloader> /
;;; <menu-entry> 框架——输入是我们自己的 <boot-plan> 记录；
;;; 框架转换在 (guixcfg boot uki-bootloader) 适配层完成。
;;;
;;; ESP 布局（全部归我们管理，记入 .deployed，其余文件一律不碰）：
;;;   /EFI/Guix/A/*.EFI          完整 deployment 槽 A
;;;   /EFI/Guix/B/*.EFI          完整 deployment 槽 B
;;;   /EFI/Guix/.deployed        所有权清单
;;;   /EFI/BOOT/BOOTX64.EFI      Limine（UEFI fallback）
;;;   /limine.conf               当前激活槽的唯一提交点
;;;
;;; 每次只重建【非活动】槽。所有 UKI 构建、签名、fsync 完成后，先原子
;;; 更新 Limine fallback，最后原子替换 limine.conf 指向新槽。因此任意
;;; 构建失败或掉电都不会让菜单看见“半套新 UKI + 半套旧 UKI”。
;;;
;;; Secure Boot：/persist/system/keys/secure-boot/db.{key,crt} 存在时
;;; ukify 直接签 UKI，sbsign 签 Limine；不存在则全部不签（开发期）。

(define-module (guixcfg boot uki)
               #:use-module (guixcfg boot boot-state)
               #:use-module (guixcfg storage model)  ; %luks-mapper-name
               #:use-module (rosenthal packages bootloaders)  ; limine、systemd-stub、ukify
               #:use-module (gnu packages efi)   ; sbsigntools
               #:use-module (guix gexp)
               #:use-module (guix modules)       ; source-module-closure
               #:use-module (guix records)       ; define-record-type*
               #:use-module (ice-9 regex)        ; string-match（cmdline-system）
               #:export (;; Boot Plan
                         <boot-plan>
                         boot-plan make-boot-plan boot-plan?
                         boot-plan-label
                         boot-plan-kernel boot-plan-initrd boot-plan-cmdline
                         boot-plan-system
                         ;; 固定位置
                         %secure-boot-keydir
                         %uki-esp-subdir
                         ;; 部署脚本生成
                         make-uki-deploy-program))

;; Secure Boot 密钥的固定语义路径（docs/boot.md 第 16.3 节）。
(define %secure-boot-keydir "/persist/system/keys/secure-boot")

;; ESP 上 UKI 的存放子目录。
(define %uki-esp-subdir "EFI/Guix")

;;; ────────────────────────────────────────────────────────────
;;; Boot Plan：一个可启动项的全部输入（框架无关）。

(define-record-type* <boot-plan>
                     boot-plan make-boot-plan
                     boot-plan?
                     (label   boot-plan-label)
                     (kernel  boot-plan-kernel)
                     (initrd  boot-plan-initrd)
                     (cmdline boot-plan-cmdline)
                     ;; 本次部署的 system 目录（/gnu/store/<hash>-system）。
                     ;; 由 menu-entry->boot-plan 从部署 cmdline 的
                     ;; gnu.system= 解析；Recovery candidate 的 identity
                     ;; 以此为准（不能从 kernel 路径 dirname 推导——布局
                     ;; 依赖，实测 bug）。#f 时部署脚本回退 cmdline 解析。
                     (system  boot-plan-system
                              (default #f)))

;;; ────────────────────────────────────────────────────────────
;;; 部署脚本：以 root 在部署期运行。

(define (make-uki-deploy-program current)
  "生成 UKI 部署脚本。CURRENT 是当前 generation 的 <boot-plan>。
Recovery 的 Guix 轴由部署期从 boot-state 注册表解析。"
  (program-file
   "deploy-uki"
   (with-imported-modules
    (source-module-closure '((guix build utils)
                             (guix build syscalls)
                             (guixcfg storage root-generation)
                             (guixcfg utils atomic-file))
                           #:select? (lambda (name)
                                       (or (guix-module-name? name)
                                           (eq? (car name) 'guixcfg))))
    #~(begin
       (use-modules ((guix build utils) #:hide (delete))
                    (guix build syscalls)
                    (guixcfg storage root-generation)
                    (guixcfg storage model)
                    (guixcfg utils atomic-file)
                    (ice-9 ftw)
                    (ice-9 rdelim)
                    (srfi srfi-1)
                    (srfi srfi-13))
       
       ;; 参数：mount-point（init 时 /mnt，reconfigure 时 /）、efi 挂载点。
       (define mount-point (cadr (command-line)))
       (define efi-target (caddr (command-line)))
       ;; 不能命名为 mount，会遮蔽 (guix build syscalls) 的 mount。
       (define mnt (string-trim-right mount-point #\/))
       (define esp (if (file-exists? (string-append mnt efi-target))
                     (string-append mnt efi-target)
                     efi-target))
       
       (define ukify-bin #$(file-append ukify "/bin/ukify"))
       (define stub-bin
         #$(file-append systemd-stub "/libexec/" (systemd-stub-name)))
       (define sbsign-bin #$(file-append sbsigntools "/bin/sbsign"))
       (define limine-bin
         #$(file-append limine "/share/limine/BOOTX64.EFI"))
       
       ;; Secure Boot 密钥存在则签名。
       (define keydir (string-append mnt #$%secure-boot-keydir))
       (define db-key (string-append keydir "/db.key"))
       (define db-crt (string-append keydir "/db.crt"))
       (define signed? (and (file-exists? db-key) (file-exists? db-crt)))
       
       (define uki-dir (string-append esp "/" #$%uki-esp-subdir))
       (define boot-dir (string-append esp "/EFI/BOOT"))
       (define config-file (string-append esp "/limine.conf"))
       (define deployed-file (string-append uki-dir "/.deployed"))
       (mkdir-p uki-dir)
       (mkdir-p boot-dir)
       
       (define (remove-path! path)
         (when (file-exists? path)
           (if (eq? (stat:type (lstat path)) 'directory)
             (delete-file-recursively path)
             (delete-file path))))
       
       ;; limine.conf 是 active-slot 的事实来源；.deployed 不是提交标记。
       ;; 旧版 flat layout 的配置不含 /A/ 或 /B/，视为“尚无活动槽”。
       (define (active-slot)
         (and (file-exists? config-file)
              (call-with-input-file config-file
                                    (lambda (port)
                                      (let loop ()
                                        (let ((line (read-line port)))
                                          (cond
                                            ((eof-object? line) #f)
                                            ((string-contains line "/EFI/Guix/A/") "A")
                                            ((string-contains line "/EFI/Guix/B/") "B")
                                            (else (loop)))))))))
       
       (define active (active-slot))
       (define target-slot (if (and active (string=? active "A")) "B" "A"))
       (define target-dir (string-append uki-dir "/" target-slot))
       (define staging-dir (string-append uki-dir "/." target-slot ".new"))
       
       ;; 历史 root 深度：临时挂 Btrfs 顶层，异常也保证卸载。
       (define prev-count
         (let ((state-path (string-append mnt
                                          "/persist/system/root-generations/state.scm")))
           (if (not (file-exists? state-path))
             0
             (let ((top "/run/guixcfg-deploy-top")
                   (mounted? #f))
               (dynamic-wind
                (lambda ()
                  (mkdir-p top)
                  (mount #$(string-append "/dev/mapper/" %luks-mapper-name)
                         top "btrfs" 0 "subvolid=5")
                  (set! mounted? #t))
                (lambda ()
                  (min 3
                       (length
                        (filter-map parse-root-generation
                                    (or (scandir top) '())))))
                (lambda ()
                  (when mounted?
                    (umount top))))))))
       
       ;; ── 1. 在非活动 staging 槽中构建完整 UKI 集合 ────────────────
       ;; 任何失败都不会改变当前 limine.conf 指向的活动槽。
       (remove-path! staging-dir)
       (remove-path! target-dir)          ; target-slot 必定是非活动槽
       (mkdir-p staging-dir)
       
       (define os-release (string-append staging-dir "/.os-release"))
       (call-with-output-file os-release
                              (lambda (port)
                                (display "NAME=\"Guix System\"\nID=guix\n" port)
                                (fsync port)))
       
       (define (build-uki kernel initrd cmdline out-name)
         (let ((out (string-append staging-dir "/" out-name)))
           (apply invoke ukify-bin "build"
             "--linux" kernel
             "--initrd" initrd
             "--cmdline" cmdline
             "--stub" stub-bin
             "--os-release" os-release
             (append
              (if signed?
                (list "--secureboot-private-key" db-key
                      "--secureboot-certificate" db-crt)
                '())
              (list "--output" out)))
           ;; ukify 已关闭输出 fd；显式 fsync 后才允许发布这个槽。
           (fsync-path! out)
           out))
       
       (define current-cmdline #$(boot-plan-cmdline current))
       (define current-kernel #$(boot-plan-kernel current))
       (define current-initrd #$(boot-plan-initrd current))
       
       (build-uki current-kernel current-initrd current-cmdline
                  "CURRENT.EFI")
       (for-each
        (lambda (k)
          (build-uki current-kernel current-initrd
                     (string-append current-cmdline
                                    " rootmode=previous:" (number->string k))
                     (string-append "PREV-" (number->string k) ".EFI")))
        (iota prev-count 1))
       ;; Recovery candidate：总是为本次部署的 system 准备（同 CURRENT 的
       ;; kernel/initrd + rootmode=recovery），并记录 system identity。
       ;; candidate 不是正式 Recovery——只有 userspace confirm 验证
       ;; candidate.system == /run/current-system 后才 promote 到稳定路径
       ;; EFI/Guix/RECOVERY.EFI（见 (guixcfg boot recovery)）。
       (build-uki current-kernel current-initrd
                  (string-append current-cmdline " rootmode=recovery")
                  "RECOVERY.EFI")
       (let ((candidate-meta (string-append uki-dir "/candidate.scm")))
         ;; candidate 的 system = 本次部署的 system 目录。从部署 cmdline
         ;; 的 gnu.system= 解析——不能从 kernel 路径 dirname 推断：
         ;; kernel 是 <hash>-linux-libre-x/bzImage 时 dirname 两次会退到
         ;; /gnu/store（实测 bug，导致 candidate 永不匹配 → promote 跳过
         ;; → limine 永不出现 Recovery 项）。
         (define (cmdline-system cmdline)
           (let ((m (string-match "gnu\\.system=([^ ]+)" cmdline)))
             (and m (match:substring m 1))))
         (let ((candidate-system (or #$(boot-plan-system current)
                                     (cmdline-system current-cmdline)
                                     (dirname (dirname current-kernel)))))
           (atomic-write-file! candidate-meta
                               (lambda (port)
                                 (write `((system . ,candidate-system)
                                          (slot . ,target-slot))
                                        port)
                                 (newline port)))))
       
       (delete-file os-release)
       ;; 先持久化 staging 内的目录项，再把完整目录发布为 target-slot。
       (fsync-path! staging-dir)
       (rename-file staging-dir target-dir)
       (fsync-path! uki-dir)
       
       ;; ── 2. 准备新的 Limine fallback 与配置，但尚不切菜单 ─────────
       (define fallback-file (string-append boot-dir "/BOOTX64.EFI"))
       (define fallback-new (string-append fallback-file ".new"))
       (define fallback-unsigned (string-append fallback-file ".unsigned"))
       (remove-path! fallback-new)
       (remove-path! fallback-unsigned)
       (if signed?
         (begin
          (copy-file limine-bin fallback-unsigned)
          (invoke sbsign-bin "--key" db-key "--cert" db-crt
                  "--output" fallback-new fallback-unsigned)
          (delete-file fallback-unsigned))
         (copy-file limine-bin fallback-new))
       (fsync-path! fallback-new)
       
       (define config-new (string-append config-file ".new"))
       (call-with-output-file config-new
                              (lambda (port)
                                (format port "\
timeout: 3

/GNU Guix
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/~a/CURRENT.EFI
" target-slot)
                                (when (> prev-count 0)
                                  (format port "\n/Previous boots\n")
                                  (for-each
                                   (lambda (k)
                                     (format port "\
    //Previous boot ~a
        protocol: efi_chainload
        image_path: boot():/EFI/Guix/~a/PREV-~a.EFI
" k target-slot k))
                                   (iota prev-count 1)))
                                ;; Recovery 入口指向稳定路径（EFI/Guix/RECOVERY.EFI）；只有
                                ;; promote 后（文件就位）才出现在菜单（见 (guixcfg boot recovery)）。
                                (when (file-exists? (string-append uki-dir "/RECOVERY.EFI"))
                                  (format port "\
/GNU Guix (Recovery)
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/RECOVERY.EFI
"))
                                (fsync port)))
       
       ;; ── 3. 提交 ─────────────────────────────────────────────────
       ;; fallback 先换：即使随后掉电，新 Limine 仍读取旧 limine.conf。
       ;; limine.conf 是最终 commit point：它一旦切换，新槽已完整持久化。
       (atomic-replace-file! fallback-new fallback-file)
       (atomic-replace-file! config-new config-file)
       
       ;; ── 4. 所有权清单与旧 flat layout 清理 ─────────────────────
       ;; 只删除旧版 .deployed 曾记录、且名字属于旧 flat UKI 白名单的文件；
       ;; 不信任清单里的任意 ../ 路径。A/B 两槽都保留，由下一次部署覆盖
       ;; 非活动槽，因此总能留下上一套完整 deployment。
       (define (legacy-flat-uki? name)
         (or (string=? name "CURRENT.EFI")
             (string=? name "RECOVERY.EFI")
             (and (string-prefix? "PREV-" name)
                  (string-suffix? ".EFI" name)
                  (not (string-contains name "/")))))
       (when (file-exists? deployed-file)
         (let ((old (false-if-exception
                     (call-with-input-file deployed-file read))))
           (when (list? old)
             (for-each
              (lambda (name)
                (when (and (string? name) (legacy-flat-uki? name))
                  (remove-path! (string-append uki-dir "/" name))))
              old))))
       (atomic-write-file! deployed-file
                           (lambda (port)
                             (write '("A" "B"
                                          "../../EFI/BOOT/BOOTX64.EFI"
                                          "../../limine.conf")
                                    port)
                             (newline port)))
       
       (format #t
               "UKI deployment ~a 已提交（~a签名，Recovery candidate 已部署；原活动槽：~a）~%"
               target-slot
               (if signed? "已" "未")
               (or active "legacy/none"))))))
