;;; file application unit：文件类型识别 CLI。

(define-module (guixcfg apps file definition)
               #:use-module (gnu packages file) ; file
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%file))

(define %file
  (application
   (name 'file)
   (home-packages (list file))))
