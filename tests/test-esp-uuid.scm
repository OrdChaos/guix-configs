;;; ESP LUKS UUID 文件机制测试：
;;;   E1  %esp-luks-uuid-file 布局常量（写侧 install/activation 与读侧
;;;       initrd 的跨进程契约，(guixcfg boot layout) 单一 authority）
;;;   E2  esp-luks-uuid-service 是 activation 扩展
;;;   E3  esp-luks-uuid-service 注册进 host OS user services
;;;       （存量机器 reconfigure 迁移路径）
;;;   E4  install 验证把 ESP UUID 文件列为必需产物
;;;
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。

(use-modules (guixcfg boot layout)          ; %esp-luks-uuid-file、%esp-mount-point
             (guixcfg boot esp-uuid)        ; esp-luks-uuid-service
             ((guixcfg hosts vm) #:prefix vm:) ; %vm-os
             (gnu system)                   ; operating-system-user-services
             (gnu services)                 ; service-kind、service-value
             (gnu services base)            ; activation-service-type
             (ice-9 textual-ports)          ; get-string-all
             (srfi srfi-1)                  ; find、any
             (srfi srfi-13)                 ; string-contains
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "esp-uuid")

;; E1：布局契约（ESP 相对路径，EFI/Guix 下，无连字符 hex 文件）。
(test-equal "E1: ESP UUID file lives under EFI/Guix"
            "EFI/Guix/luks-uuid"
            %esp-luks-uuid-file)

;; E2：service 扩展 activation-service-type（tests/test-flatpak-service.scm
;; 同款 simple-service 判定模式）。
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

(test-assert "E2: esp-luks-uuid-service extends activation-service-type"
             (service-extends? esp-luks-uuid-service activation-service-type))

;; E3：注册进 host user services（reconfigure/boot activation 路径）。
(test-assert "E3: esp-luks-uuid-service registered in %vm-os user services"
             (find (lambda (svc)
                     (eq? svc esp-luks-uuid-service))
                   (operating-system-user-services vm:%vm-os)))

;; E4：validate-installation 的必需产物清单覆盖 ESP UUID 文件
;; （静态断言：install.scm 源内引用 %esp-luks-uuid-file）。
(test-assert "E4: install validation references the ESP UUID file"
             (let ((source (call-with-input-file
                            "modules/guixcfg/system/install.scm"
                            get-string-all)))
               (string-contains source "%esp-luks-uuid-file")))

(test-end "esp-uuid")
