;;; UKI 部署核心（deploy-core）：把 Boot Plan 部署成 ESP 上的
;;; Limine 菜单 + UKI。本模块【不依赖】Guix 的 <bootloader> /
;;; <menu-entry> 框架——输入是我们自己的 <boot-plan> 记录；
;;; 框架转换在 (guixcfg boot uki-bootloader) 适配层完成
;;; （GCD006 重写框架时只需改适配层）。
;;;
;;; ESP 布局（全部归我们管理，记入 .deployed，其余文件一律不碰）：
;;;   /EFI/Guix/CURRENT.EFI     当前 generation（normal）
;;;   /EFI/Guix/LAST-GOOD.EFI   最后确认启动成功的 generation
;;;                             （数据源：(guixcfg boot boot-state)
;;;                             注册表；部署成功 ≠ 启动成功）
;;;   /EFI/Guix/RECOVERY.EFI    当前 generation + rootmode=recovery
;;;   /EFI/BOOT/BOOTX64.EFI     Limine（UEFI fallback，无启动项也能进菜单）
;;;   /limine.conf              Limine 配置（三项菜单，chainload UKI）
;;;
;;; Secure Boot：/persist/system/keys/secure-boot/db.{key,crt} 存在时
;;; 用 sbsign 签 UKI 与 Limine；不存在则全部不签（开发期）。

(define-module (guixcfg boot uki)
               #:use-module (guixcfg boot boot-state)
               #:use-module (guixcfg storage model)  ; %luks-mapper-name
               #:use-module (rosenthal packages bootloaders)  ; limine、systemd-stub、ukify
               #:use-module (gnu packages efi)   ; sbsigntools
               #:use-module (guix gexp)
               #:use-module (guix modules)       ; source-module-closure
               #:use-module (guix records)       ; define-record-type*
               #:export (;; Boot Plan
                         <boot-plan>
                         boot-plan make-boot-plan boot-plan?
                         boot-plan-label
                         boot-plan-kernel boot-plan-initrd boot-plan-cmdline
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
                     (label   boot-plan-label)    ; 显示名（字符串）
                     (kernel  boot-plan-kernel)   ; bzImage（store 路径）
                     (initrd  boot-plan-initrd)   ; initrd（store 路径）
                     (cmdline boot-plan-cmdline)) ; 内核命令行（产生字符串的 gexp）

;;; ────────────────────────────────────────────────────────────
;;; 部署脚本：以 root 在部署期运行。

(define (make-uki-deploy-program current)
  "生成 UKI 部署脚本（program-file）。CURRENT 是当前 generation 的
<boot-plan>。Last Good 由脚本在部署期从 boot-state 注册表解析，
不由调用方提供。"
  (program-file
   "deploy-uki"
   (with-imported-modules
    (source-module-closure '((guix build utils)
                             (guix build syscalls)
                             (guixcfg boot boot-state)
                             (guixcfg storage root-generation))
                           #:select? (lambda (name)
                                       (or (guix-module-name? name)
                                           (eq? (car name) 'guixcfg))))
    #~(begin
       (use-modules (guix build utils)
                    (guix build syscalls)     ; mount、umount（统计历史 root）
                    (guixcfg boot boot-state)
                    (guixcfg storage root-generation)
                    (guixcfg storage model)   ; parse-root-generation
                    (ice-9 ftw)              ; scandir
                    (srfi srfi-1)            ; second/third/fourth
                    (srfi srfi-13))
       
       ;; 参数：mount-point（init 时 /mnt，reconfigure 时 /）、efi 挂载点
       (define mount-point (cadr (command-line)))
       (define efi-target (caddr (command-line)))
       ;; 注意命名不能叫 mount——会遮蔽 (guix build syscalls) 的 mount 过程
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
       
       ;; Secure Boot 密钥存在则签名
       (define keydir (string-append mnt #$%secure-boot-keydir))
       (define db-key (string-append keydir "/db.key"))
       (define db-crt (string-append keydir "/db.crt"))
       (define signed? (and (file-exists? db-key) (file-exists? db-crt)))
       
       (define uki-dir (string-append esp "/" #$%uki-esp-subdir))
       (define boot-dir (string-append esp "/EFI/BOOT"))
       (mkdir-p uki-dir)
       (mkdir-p boot-dir)
       
       ;; .osrel 段内容（UKI 规范）
       (define os-release
         (string-append (getcwd) "/os-release"))
       (call-with-output-file os-release
                              (lambda (port)
                                (display "NAME=\"Guix System\"\nID=guix\n" port)))
       
       (define (build-uki kernel initrd cmdline out-name)
         (let ((out (string-append uki-dir "/" out-name)))
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
           out))
       
       (define (sign-efi file)
         (when signed?
           (invoke sbsign-bin "--key" db-key "--cert" db-crt
                   "--output" file file)))
       
       ;; 烘入脚本的当前条目（boot-plan 各字段）
       (define current-cmdline #$(boot-plan-cmdline current))
       
       ;; Last Good：boot-state 注册表 → system-N-link → 条目
       ;; （部署成功 ≠ 启动成功；注册表只由用户态 confirm 更新）
       (define last-good
         (resolve-generation mnt (read-boot-states
                                  (string-append mnt
                                                 "/persist/system/boot-states.scm"))))
       
       ;; 历史启动可用深度：挂 Btrfs 顶层数现存 root
       ;; （Previous 1 即最新那次，不需要排除任何项）。
       ;; PREV-K 只在确实存在时生成/显示（部署期保守估计；此后只会
       ;; 更多不会更少——rotation 只增、cleanup 保底 keep 个）。
       ;; init 首次部署时状态文件尚不存在（commit-root 才写），按 0 计。
       (define prev-count
         (let ((state-path (string-append mnt
                                          "/persist/system/root-generations/state.scm")))
           (if (not (file-exists? state-path))
             0
             (let ((top "/run/guixcfg-deploy-top"))
               (mkdir-p top)
               (mount #$(string-append "/dev/mapper/" %luks-mapper-name)
                      top "btrfs" 0 "subvolid=5")
               (let ((names (scandir top)))
                 (umount top)
                 (min 3
                      (length
                       (filter-map parse-root-generation
                                   (or names '())))))))))
       
       ;; 1. 构建 UKI
       ;;    CURRENT：当前系统 + fresh root（normal）
       ;;    PREV-K：当前系统 + 往前第 K 个 root（previous:K 是
       ;;            运行期相对选择器，initrd 启动时解析，不过期）
       ;;    RECOVERY：last-good 系统 + last-good root
       ;;            （rootmode=recovery；无 last-good 记录时不生成）
       (build-uki #$(boot-plan-kernel current)
                  #$(boot-plan-initrd current)
                  current-cmdline
                  "CURRENT.EFI")
       (for-each
        (lambda (k)
          (build-uki #$(boot-plan-kernel current)
                     #$(boot-plan-initrd current)
                     (string-append current-cmdline
                                    " rootmode=previous:" (number->string k))
                     (string-append "PREV-" (number->string k) ".EFI")))
        (iota prev-count 1))
       (when last-good
         (build-uki (second last-good)
                    (third last-good)
                    (string-append (fourth last-good) " rootmode=recovery")
                    "RECOVERY.EFI"))
       
       ;; 2. Limine：二进制 + 配置
       ;;    菜单：正常启动 / Previous boots（折叠子菜单，前 3 次）/
       ;;    Recovery（last-good 系统 + last-good root）。
       ;;    注意菜单文本避免 CJK——Limine 内置字体没有中文字形。
       (copy-file limine-bin (string-append boot-dir "/BOOTX64.EFI"))
       (sign-efi (string-append boot-dir "/BOOTX64.EFI"))
       (call-with-output-file (string-append esp "/limine.conf")
                              (lambda (port)
                                (format port "\
timeout: 3

/GNU Guix
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/CURRENT.EFI
")
                                ;; 历史启动子菜单：只有实际存在的 root 才出现
                                (when (> prev-count 0)
                                  (format port "\n/Previous boots\n")
                                  (for-each
                                   (lambda (k)
                                     (format port "\
    //Previous boot ~a
        protocol: efi_chainload
        image_path: boot():/EFI/Guix/PREV-~a.EFI
" k k))
                                   (iota prev-count 1)))
                                (when last-good
                                  (format port "\
/GNU Guix (Recovery)
    protocol: efi_chainload
    image_path: boot():/EFI/Guix/RECOVERY.EFI
"))))
       
       ;; 3. .deployed 清单：只清理我们部署过且这次不再需要的文件
       (define deployed-file (string-append uki-dir "/.deployed"))
       (define wanted
         (append (list "CURRENT.EFI"
                       "../../EFI/BOOT/BOOTX64.EFI"
                       "../../../limine.conf")
                 (map (lambda (k)
                        (string-append "PREV-" (number->string k) ".EFI"))
                      (iota prev-count 1))
                 (if last-good '("RECOVERY.EFI") '())))
       (when (file-exists? deployed-file)
         (for-each
          (lambda (old)
            (unless (member old wanted)
              (delete-file (string-append uki-dir "/" old))))
          (call-with-input-file deployed-file read)))
       (call-with-output-file deployed-file
                              (lambda (port) (write wanted port) (newline port)))
       
       (format #t "UKI 部署完成（~a签名，Recovery 项：~a）~%"
               (if signed? "已" "未")
               (if last-good "有" "无"))))))
