;;; DupriMan virtual CUPS queue and runtime state projection.

(define-module (guixcfg system printing dupriman)
  #:use-module (gnu packages base)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (guix gexp)
  #:use-module (guixcfg system printing model)
  #:use-module (guixcfg users user)
  #:use-module (virelith packages dupriman)
  #:export (dupriman-bridge-group-name dupriman-queue
            %dupriman-printing-services))

(define dupriman-bridge-group-name
  (string-append "dupriman-" (user-profile-name %primary-user)))

(define %dupriman-config
  (mixed-text-file
   "dupriman-config.toml"
   "[printer]\n"
   "real = \"hp-laserjet-1020\"\n"
   "\n[paths]\n"
   "state_dir = \"/run/dupriman\"\n"
   "spool_dir = \"/var/tmp/dupriman\"\n"
   "\n[prompt]\n"
   "allowed_users = [\"" (user-profile-name %primary-user) "\"]\n"))

(define dupriman-queue
  (printer-queue
   (name "dupriman-duplex")
   (device-uri "dupriman://duplex")
   (ppd (file-append dupriman "/share/cups/model/dupriman.ppd"))
   (driver-packages (list dupriman))
   (options '("media-default=A4"))))

(define (dupriman-runtime-activation)
  #~(begin
      (use-modules (guix build utils))
      (define install #$(file-append coreutils "/bin/install"))
      (define (directory mode owner group path)
        (invoke install "-d" "-m" mode "-o" owner "-g" group path))
      (directory "0711" "root" "root" "/run/dupriman")
      (directory "0711" "root" "root"
                 #$(string-append "/run/dupriman/"
                                  (user-profile-name %primary-user)))
      (directory "2750" "lp" #$dupriman-bridge-group-name
                 #$(string-append "/run/dupriman/"
                                  (user-profile-name %primary-user)
                                  "/requests"))
      (directory "2770" #$(user-profile-name %primary-user)
                 #$dupriman-bridge-group-name
                 #$(string-append "/run/dupriman/"
                                  (user-profile-name %primary-user)
                                  "/responses"))
      (directory "0700" "lp" "lp" "/var/tmp/dupriman")))

(define %dupriman-printing-services
  (list (simple-service 'dupriman-config etc-service-type
                        `(("dupriman/config.toml" ,%dupriman-config)))
        (simple-service 'dupriman-runtime-directories activation-service-type
                        (dupriman-runtime-activation))))
