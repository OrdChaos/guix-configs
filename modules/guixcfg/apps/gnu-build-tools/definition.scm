;;; GNU build tools application unit.

(define-module (guixcfg apps gnu-build-tools definition)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bison)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages compiler-tools)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages m4)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages texinfo)
  #:use-module (guix records)
  #:use-module (guixcfg apps model)
  #:export (%gnu-build-tools))

(define %gnu-build-tools
  (application
   (name 'gnu-build-tools)
    (home-packages
     (list gcc-toolchain
           gnu-make
           autoconf
           automake
           libtool
           bison
           flex
           gnu-gettext
           m4
           pkg-config
           texinfo))))
