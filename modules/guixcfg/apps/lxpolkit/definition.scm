;;; lxpolkit application unit：graphical polkit agent（niri config
;;; spawn-at-startup "lxpolkit"）。consumer 名 = lxpolkit；二进制由
;;; lxsession 包提供（lxsession 是上游包名，这里只取 agent 用途）。

(define-module (guixcfg apps lxpolkit definition)
               #:use-module (gnu packages lxde) ; lxsession（lxpolkit）
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%lxpolkit))

(define %lxpolkit
  (application
   (name 'lxpolkit)
   (home-packages (list lxsession))))
