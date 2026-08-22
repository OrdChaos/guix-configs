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
               #:use-module (ice-9 regex)   ; string-match（gnu.system= 解析）
               #:export (uki-bootloader))

;; 部署脚本在目标系统上的落点（install-boot-config 复制到这里）。
(define %deploy-script-path "/boot/deploy-uki")

;;; ────────────────────────────────────────────────────────────
;;; 1. menu-entry → boot-plan

(define (menu-entry->boot-plan entry)
  ;; system：部署 cmdline 的 gnu.system=（guix 注入的部署权威路径）。
  ;; boot-plan 显式携带，供 Recovery candidate 的 identity 匹配
  ;; （不能从 kernel 路径 dirname 推导——布局依赖，实测 bug）。
  ;; 注意：guix 注入的 kernel-arguments 是 gexp（配置期非字符串），
  ;; 所以 system 是延迟 gexp（部署脚本内对求值后的 cmdline 解析）。
  (boot-plan
   (label (menu-entry-label entry))
   (kernel (menu-entry-linux entry))
   (initrd (menu-entry-initrd entry))
   (cmdline #~(string-join (list #$@(menu-entry-linux-arguments entry)) " "))
   (system #~(let ((m (string-match "gnu\\.system=([^ ]+)"
                                    (string-join (list #$@(menu-entry-linux-arguments entry))
                                                 " "))))
               (and m (match:substring m 1))))))

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
