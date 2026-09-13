;;; Secure Boot material inventory shared by installation and enrollment.

(define-module (guixcfg security secure-boot-material)
               #:export (%secure-boot-key-file-names
                         %secure-boot-keystore-auth-paths))

(define %secure-boot-key-file-names
  '("PK.key" "PK.crt" "KEK.key" "KEK.crt" "db.key" "db.crt"))

(define %secure-boot-keystore-auth-paths
  '("PK/PK.auth" "KEK/KEK.auth" "db/db.auth"))
