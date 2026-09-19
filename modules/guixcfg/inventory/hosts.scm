;;; Host ID 与部署后 hostname 的单一映射。
;;;
;;; Host ID 仍由 modules/guixcfg/hosts/*.scm 的文件名定义；本表只表达
;;; 已启动机器如何反查自己的 Host ID，供无参数 blue reconfigure 使用。

(define-module (guixcfg inventory hosts)
               #:use-module (srfi srfi-1)
               #:export (%host-identity-table
                         host-id-for-hostname
                         host-name-for-id))

(define %host-identity-table
  '(("lenovo-legion-y7000p" . "ordchaos-lenovo-pc")
    ("vm" . "guix-vm")))

(define (host-id-for-hostname hostname)
  "返回 HOSTNAME 精确对应的 Host ID；未知 hostname 返回 #f。"
  (and=> (find (lambda (entry)
                 (string=? hostname (cdr entry)))
               %host-identity-table)
         car))

(define (host-name-for-id host-id)
  "返回 HOST-ID 对应的 hostname；未知 Host ID 立即失败。"
  (or (and=> (find (lambda (entry)
                     (string=? host-id (car entry)))
                   %host-identity-table)
             cdr)
      (error "host ID has no hostname identity:" host-id)))
