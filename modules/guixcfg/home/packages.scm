;;; Minimal Guix Home 的用户包集合（normal-user CLI tools only）。
;;; System/security tooling（cryptsetup、btrfs-progs、tpm2-tools、
;;; sbkeysync、efibootmgr）不属于 Home——它们由 Guix System 拥有。

(define-module (guixcfg home packages)
               #:use-module (gnu packages admin)      ; tree
               #:use-module (gnu packages compression) ; unzip、zip
               #:use-module (gnu packages curl)    ; curl
               #:use-module (gnu packages file)    ; file
               #:use-module (gnu packages less)    ; less
               #:use-module (gnu packages version-control) ; git
               #:use-module (gnu packages rust-apps) ; fd、ripgrep
               #:use-module (gnu packages wget)    ; wget
               #:use-module (gnu packages web)     ; jq
               #:export (%home-packages))

(define %home-packages
  (list git ripgrep fd tree jq curl wget unzip zip less file))
