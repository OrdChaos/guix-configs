;;; zip application unit：压缩/解压工具族（zip + unzip 同一单元）。

(define-module (guixcfg apps zip definition)
               #:use-module (gnu packages compression) ; unzip、zip
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%zip))

(define %zip
  (application
   (name 'zip)
   (home-packages (list unzip zip))))
