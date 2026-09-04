;;; mesa-utils application unit：Mesa/GL 诊断 CLI（glxinfo /
;;; eglinfo / glxgears）——图形栈排障（Xwayland/GL 渲染验证，
;;; 2026-09 加入）。

(define-module (guixcfg apps mesa-utils definition)
               #:use-module (gnu packages gl) ; mesa-utils
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%mesa-utils))

(define %mesa-utils
  (application
   (name 'mesa-utils)
   (home-packages (list mesa-utils))))
