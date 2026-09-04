;;; Node.js application unit：Node.js 运行时（含 npm）+ pnpm。
;;;
;;; node 来自 pinned guix（gnu packages node，自带 npm）；pnpm 来自
;;; virelith（pnpm 不在 pinned guix——virelith packages nodejs，
;;; 2026-09 加入）。

(define-module (guixcfg apps nodejs definition)
               #:use-module (gnu packages node)      ; node（含 npm）
               #:use-module (virelith packages nodejs) ; pnpm
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%nodejs))

(define %nodejs
  (application
   (name 'nodejs)
   (home-packages (list node pnpm))))
