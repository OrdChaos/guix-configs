;;; UKI bootloader：Guix bootloader 框架（<bootloader> / <menu-entry> /
;;; <bootloader-configuration>）与我们的 UKI 核心（(guixcfg boot uki)）
;;; 之间的【唯一】适配层。
;;;
;;; Guix 社区有重写 bootloader 子系统的提案（GCD006，
;;; issues.guix.gnu.org/79248），<menu-entry>、<bootloader> 的调用
;;; 约定未来可能变化或被替换。框架相关的知识全部集中在本文件：
;;;   1. menu-entry → uki-entry 的转换
;;;   2. configuration-file-generator 的调用签名
;;;      （(config entries #:key old-entries ...)）
;;;   3. install-boot-config / installer 的调用约定
;;;      （脚本复制到 configuration-file 路径；installer 收到
;;;      (package target mount-point)）
;;;   4. <bootloader> 记录
;;; 框架重写时只需修改本文件，UKI 核心不动。

(define-module (guixcfg boot uki-bootloader)
               #:use-module (guixcfg boot uki)
               #:use-module (gnu bootloader)
               #:use-module (guix gexp)
               #:use-module (guix records)
               #:export (%deploy-script-path
                         uki-bootloader))

;; 部署脚本在目标系统上的落点（install-boot-config 复制到这里）。
(define %deploy-script-path "/boot/deploy-uki")

;;; ────────────────────────────────────────────────────────────
;;; 1. menu-entry → boot-plan

(define (menu-entry->boot-plan entry)
  (boot-plan
   (label (menu-entry-label entry))
   (kernel (menu-entry-linux entry))
   (initrd (menu-entry-initrd entry))
   (cmdline #~(string-join
               (list #$@(menu-entry-linux-arguments entry)) " "))))

;;; ────────────────────────────────────────────────────────────
;;; 2–3. 框架调用约定：generator 与 installer

(define* (uki-configuration-file config entries
                                 #:key (old-entries '())
                                 #:allow-other-keys)
         "框架的 configuration-file-generator：当前 generation 转成 Boot Plan，
生成部署脚本。Last Good 不由框架提供（old-entries 有意忽略）——
它由部署脚本从 boot-state 注册表解析，语义见 (guixcfg boot uki)。"
         (make-uki-deploy-program (menu-entry->boot-plan (car entries))))

(define install-uki
  ;; 框架的 installer 调用约定：(package target mount-point)。
  #~(lambda (bootloader target mount-point)
      (when target
        (invoke (string-append mount-point #$%deploy-script-path)
                mount-point target))))

;;; ────────────────────────────────────────────────────────────
;;; 4. <bootloader> 记录

(define uki-bootloader
  (bootloader
   (name 'uki)
   (package (@ (rosenthal packages bootloaders) ukify))  ; 占位（未使用）
   (installer install-uki)
   (configuration-file %deploy-script-path)
   (configuration-file-generator uki-configuration-file)))
