;;; Tailscale 系统服务单元测试。
;;;
;;; 不连接任何真实 Headscale/DERP，也不读取/断言真实 preauth key
;;; 内容；只验证 profile 级入网模型、service graph、参数构造、secret
;;; 声明和 machine-state 规则。测试数据全部是 fixture。

(use-modules (guix gexp) ;local-file?、lower-object
             (guix store) ;open-connection
             (guix monads) ;run-with-store
             (guix derivations) ;build-derivations、derivation->output-path
             (gnu services) ;service、service-kind、service-value
             (gnu services shepherd) ;shepherd-service
             (rosenthal services networking) ;tailscale-configuration getters
             (guixcfg system tailscale service)
             (guixcfg system machine-state-persistence)
             (guixcfg security secrets) ;secret-decl getters
             (ice-9 rdelim) ;read-line
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(define %fixture-login-server
  "https://fixture.invalid:9443")

(define %fixture-key-file
  "/run/fixture/tailscale-enroll")

(define %fixture-operator
  "fixture-operator")

(define %fixture-config
  (tailscale-enrollment-configuration (login-server %fixture-login-server)
                                      (auth-key-file %fixture-key-file)
                                      (accept-dns? #f)
                                      (accept-routes? #f)
                                      (netfilter-mode 'off)
                                      (timeout "5s")))

(define %fixture-services
  (tailscale-services #:login-server %fixture-login-server
                      #:operator %fixture-operator
                      #:auth-key-file %fixture-key-file
                      #:timeout "5s"))

(test-begin "tailscale")

;; ── Tailscale client service ────────────────────────────────
(define %tailscaled-service
  (find (lambda (svc)
          (eq? 'tailscaled
               (service-type-name (service-kind svc)))) %fixture-services))

(test-assert "T1: exactly one tailscaled service is contributed"
             (and %tailscaled-service
                  (= 1
                     (length (filter (lambda (svc)
                                       (and (service? svc)
                                            (eq? 'tailscaled
                                                 (service-type-name (service-kind
                                                                     svc)))))
                                     %fixture-services)))))

(test-assert "T1: tailscaled state dir and socket are stable paths"
             (let ((text (object->string (service-value %tailscaled-service))))
               (and (string-contains text %tailscale-state-directory)
                    (string-contains text "/run/tailscale/tailscaled.sock"))))

(test-assert
 "T1: tailscaled pins the WireGuard port used by mihomo exclusions"
 (string-contains (object->string (service-value %tailscaled-service))
                  "--port=41641"))

;; ── first-boot enrollment ───────────────────────────────────
(define %enroll-service
  (find (lambda (svc)
          (and (service? svc)
               (eq? 'tailscale-enroll
                    (service-type-name (service-kind svc)))))
        %fixture-services))

(define %enroll-shepherd
  (tailscale-enroll-shepherd-service #:config %fixture-config))

(test-assert "T2: enrollment one-shot is contributed" %enroll-service)

(test-assert "T2: enrollment requires daemon, secrets and networking"
             (let ((req (shepherd-service-requirement %enroll-shepherd)))
               (and (memq 'tailscaled req)
                    (memq 'ordinary-secrets-ready req)
                    (memq 'networking req))))

(test-assert "T2: enrollment is a one-shot without respawn"
             (and (shepherd-service-one-shot? %enroll-shepherd)
                  (not (shepherd-service-respawn? %enroll-shepherd))))

;; ── argument construction ───────────────────────────────────
(define %up-arguments
  (tailscale-up-arguments %fixture-config))

(test-assert "T3: up uses login-server and file-based auth key"
             (and (member "up" %up-arguments)
                  (member "--login-server" %up-arguments)
                  (member %fixture-login-server %up-arguments)
                  (member (string-append "--auth-key=file:" %fixture-key-file)
                          %up-arguments)))

(test-assert "T3: up disables DNS/netfilter and does not accept routes"
             (and (member "--accept-dns=false" %up-arguments)
                  (member "--accept-routes=false" %up-arguments)
                  (member "--netfilter-mode=off" %up-arguments)))

(test-assert "T3: up has a bounded wait"
             (member "--timeout=5s" %up-arguments))

(test-assert "T3: unsupported netfilter mode is rejected"
             (catch #t
                    (lambda ()
                      (tailscale-up-arguments (tailscale-enrollment-configuration
                                               (login-server
                                                %fixture-login-server)
                                               (auth-key-file
                                                %fixture-key-file)
                                               (netfilter-mode 'fixture-invalid)))
                      #f)
                    (lambda args
                      #t)))

;; ── secret + persistence ────────────────────────────────────
(define %enroll-secret
  (find (lambda (decl)
          (eq? 'tailscale-enrollment
               (secret-decl-name decl))) %tailscale-secrets))

(test-assert "T4: profile-scoped enrollment secret is ordinary/system"
             (and %enroll-secret
                  (eq? 'system
                       (secret-decl-scope %enroll-secret))
                  (eq? 'ordinary
                       (secret-decl-domain %enroll-secret))
                  (string=? "tailscale-enroll"
                            (secret-decl-target-name %enroll-secret))
                  (= 256
                     (secret-decl-mode %enroll-secret))))

(test-assert "T4: secret source is a local age ciphertext"
             (let ((source (secret-decl-source %enroll-secret)))
               (and (local-file? source)
                    (string-suffix? "enroll.age"
                                    (local-file-name source))
                    (file-exists?
                     "modules/guixcfg/system/tailscale/secrets/enroll.age"))))

(test-assert "T4: secret source is not plaintext"
             (call-with-input-file "modules/guixcfg/system/tailscale/secrets/enroll.age"
               (lambda (port)
                 (let ((first (read-line port)))
                   (and first
                        (string-prefix? "-----BEGIN AGE ENCRYPTED FILE-----"
                                        first))))))

(test-assert "T5: state persistence uses the canonical machine-state root"
             (and (valid-machine-state-persistence-rule?
                   %tailscale-data-persistence-rule)
                  (string=? (machine-state-persistence-rule-backing
                             %tailscale-data-persistence-rule) "tailscale")
                  (string=? (machine-state-persistence-rule-consumer
                             %tailscale-data-persistence-rule)
                            %tailscale-state-directory)))

;; ── generated enrollment behavior (fake tailscale, no network) ─────
(define %fixture-dir
  (string-append "/tmp/guixcfg-tailscale-fixture-"
                 (number->string (getpid))))
(define %fake-tailscale
  (string-append %fixture-dir "/tailscale"))
(define %fixture-status
  (string-append %fixture-dir "/status.json"))
(define %fixture-argv
  (string-append %fixture-dir "/argv.txt"))

(unless (file-exists? %fixture-dir)
  (mkdir %fixture-dir))

(call-with-output-file %fake-tailscale
  (lambda (port)
    (display "#!/bin/sh\n" port)
    (display "if [ \"$1\" = status ]; then\n" port)
    (display "  cat \"$FAKE_STATUS\"\n" port)
    (display "  exit 0\n" port)
    (display "fi\n" port)
    (display "printf '%s\\n' \"$@\" >> \"$FAKE_ARGV\"\n" port)
    (display "exit 0\n" port)))
(chmod %fake-tailscale #o755)

(define %store
  (open-connection))

(define (enrollment-script)
  (let ((object (run-with-store %store
                                (lower-object (tailscale-enroll-program
                                               #:config %fixture-config
                                               #:tailscale-command
                                               %fake-tailscale)))))
    (if (string? object) object
        (begin
          (build-derivations %store
                             (list object))
          (derivation->output-path object)))))

(define (write-fixture-status text)
  (call-with-output-file %fixture-status
    (lambda (port)
      (display text port))))

(define (read-fixture-argv)
  (if (file-exists? %fixture-argv)
      (call-with-input-file %fixture-argv
        (lambda (port)
          (let loop
            ((line (read-line port))
             (acc '()))
            (if (eof-object? line)
                (reverse acc)
                (loop (read-line port)
                      (cons line acc))))))
      '()))

(define (run-enrollment status)
  (write-fixture-status status)
  (when (file-exists? %fixture-argv)
    (delete-file %fixture-argv))
  (setenv "FAKE_STATUS" %fixture-status)
  (setenv "FAKE_ARGV" %fixture-argv)
  (system* (enrollment-script)))

(test-assert "T6: NeedsLogin triggers up with file-based key"
             (let ((rc (run-enrollment
                        "{\"BackendState\":\"NeedsLogin\",\"Self\":null}")))
               (and (zero? rc)
                    (member "up"
                            (read-fixture-argv))
                    (member (string-append "--auth-key=file:"
                                           %fixture-key-file)
                            (read-fixture-argv)))))

(test-assert "T6: up arguments do not contain the key value"
             (let ((text (call-with-input-file %fixture-argv
                           get-string-all)))
               (not (string-contains text "fixture-secret-value"))))

(test-assert "T6: already Stopped by user does not force up"
             (let ((rc (run-enrollment
                        "{\"BackendState\":\"Stopped\",\"Self\":{\"ID\":\"fixture\"}}")))
               (and (zero? rc)
                    (null? (read-fixture-argv)))))

;; ── operator service (single switch without root) ───────────
(define %operator-service
  (find (lambda (svc)
          (and (service? svc)
               (eq? 'tailscale-operator
                    (service-type-name (service-kind svc)))))
        %fixture-services))

(test-assert "T7: operator service is contributed" %operator-service)

(define (operator-script)
  (let ((object (run-with-store %store
                                (lower-object (tailscale-operator-program
                                               #:operator %fixture-operator
                                               #:tailscale-command
                                               %fake-tailscale)))))
    (if (string? object) object
        (begin
          (build-derivations %store
                             (list object))
          (derivation->output-path object)))))

(test-assert "T7: operator program sets the configured user"
             (let ((script (operator-script)))
               (when (file-exists? %fixture-argv)
                 (delete-file %fixture-argv))
               (setenv "FAKE_ARGV" %fixture-argv)
               (and (zero? (system* script))
                    (equal? (read-fixture-argv)
                            (list "set" "--operator" %fixture-operator)))))
(test-end "tailscale")
