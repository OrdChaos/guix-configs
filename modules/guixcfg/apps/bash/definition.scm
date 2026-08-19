;;; Bash application unit。所有权边界：System 拥有 /etc/passwd
;;; login shell；Home（本 app）拥有 shell rc、别名与环境变量。

(define-module (guixcfg apps bash definition)
               #:use-module (gnu services)                 ; service
               #:use-module (gnu home services shells)     ; home-bash-service-type
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%bash))

(define %bash
  (application
   (name 'bash)
   (home-services
    (list (service home-bash-service-type
                   (home-bash-configuration
                    (environment-variables
                     '(("EDITOR" . "nano")
                       ("VISUAL" . "nano")
                       ("PAGER" . "less")))))))))
