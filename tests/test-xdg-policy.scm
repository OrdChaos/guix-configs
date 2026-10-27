;;; 统一 XDG/default-apps 策略测试（(guixcfg home xdg)）：
;;; mimeapps.list 默认应用表的结构不变量——每个 MIME 恰好一个
;;; default（跨组重复 key 会生成语义不确定的 mimeapps.list）、
;;; 每个 default 值恰好一个 desktop entry、office 组指向 ONLYOFFICE
;;; desktop entry；实际序列化的关联在无 mimeinfo.cache 时能被 GIO
;;; 发现，URL handler 保留参数与 immutable-extension executable。
;;;
;;; 加应用不要求改本测试：断言只检查策略表的结构与领域边界，不枚举
;;; per-app 关联清单（完整清单在 office 组注释里，由上游 desktop
;;; entry 的 MimeType 实证）。

(use-modules (guixcfg home xdg)
             (guixcfg apps onlyoffice definition) ;%onlyoffice-desktop-entry
             (guixcfg apps vscode definition)
             (guixcfg apps model)
             (gnu home services)
             (gnu home services xdg)
             (gnu packages glib)
             (gnu packages freedesktop)
             (gnu services)
             (guix build utils)
             (guix store)
             (guix monads)
             (guix derivations)
             (guix gexp)
             (guix utils)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "xdg-policy")

(define %keys
  (map car %xdg-default-applications))

(test-assert "every mime key appears exactly once (no duplicate defaults)"
             (= (length %keys)
                (length (delete-duplicates %keys))))

(test-assert "every default value is a single desktop entry"
             (every (lambda (entry)
                      (and (pair? entry)
                           (string? (car entry))
                           (pair? (cdr entry))
                           (string? (cadr entry))
                           (null? (cddr entry)))) %xdg-default-applications))

;; office 组 = 默认值恰为 ONLYOFFICE desktop entry 的 MIME 集合
;; （key 唯一性已断言，按值反查可靠）。
(define %office-keys
  (filter (lambda (k)
            (equal? (assoc-ref %xdg-default-applications k)
                    (list %onlyoffice-desktop-entry))) %keys))

(test-assert "office mime types default to the ONLYOFFICE desktop entry"
             (pair? %office-keys))

;; Exercise the official serializer and GIO, without depending on installed
;; user applications, desktop caches, a graphical session or the network.
(define %store
  (open-connection))

(define* (materialize object
                      #:optional (output "out"))
  (let ((drv (run-with-store %store
                             (lower-object object))))
    (if (string? drv) drv
        (begin
          (build-derivations %store
                             (list drv))
          (derivation->output-path drv output)))))

(define (extension-value type value target)
  ((service-extension-compute (find (lambda (extension)
                                      (eq? target
                                           (service-extension-target extension)))
                                    (service-type-extensions type)))
   value))

(define %mimeapps-file
  (materialize (cadr (assoc "mimeapps.list"
                            (extension-value
                             home-xdg-mime-applications-service-type
                             (service-value %xdg-default-apps-service)
                             home-xdg-configuration-files-service-type)))))

(define %url-service
  (find (lambda (service)
          (eq? 'vscode-url-handler
               (service-type-name (service-kind service))))
        (application-home-services %vscode)))

(define %url-file
  (materialize (cadr (assoc (string-append "applications/"
                                           %vscode-url-desktop-entry)
                            (extension-value (service-kind %url-service)
                                             (service-value %url-service)
                                             home-xdg-data-files-service-type)))))

(define %url-content
  (call-with-input-file %url-file
    get-string-all))
(define %vscode-output
  (materialize (car (application-home-packages %vscode))))

(test-assert "URL entry forwards URLs to the installed extension wrapper"
             (and (string-contains %url-content
                                   (string-append "Exec=" %vscode-output
                                    "/bin/code --ozone-platform-hint=auto --open-url %U
"))
                  (string-contains %url-content "NoDisplay=true\n")
                  (string-contains %url-content
                                   "MimeType=x-scheme-handler/vscode;\n")))

(define %gio
  (string-append (materialize glib "bin") "/bin/gio"))

;; A raw-key uniqueness check is insufficient: aliases such as audio/wav
;; and audio/vnd.wave must not select different players after GIO unaliases.
(test-assert "MIME aliases and canonical names have the same default"
             (call-with-input-file (string-append (materialize
                                                   shared-mime-info)
                                                  "/share/mime/aliases")
               (lambda (port)
                 (let loop
                   ((line (read-line port)))
                   (or (eof-object? line)
                       (let* ((names (string-split line #\space))
                              (alias (assoc-ref %xdg-default-applications
                                                (car names)))
                              (canonical (assoc-ref %xdg-default-applications
                                                    (cadr names))))
                         (and (or (not alias)
                                  (not canonical)
                                  (equal? alias canonical))
                              (loop (read-line port)))))))))

(let* ((root (mkdtemp "/tmp/guixcfg-xdg-policy-XXXXXX"))
       (config (string-append root "/config"))
       (data (string-append root "/data"))
       (exports (string-append root "/flatpak-exports"))
       (applications (string-append exports "/applications"))
       (mime "x-scheme-handler/tg")
       (desktop (cadr (assoc mime %xdg-default-applications))))
  (dynamic-wind (lambda ()
                  (for-each mkdir-p
                            (list config data applications))
                  (copy-file %mimeapps-file
                             (string-append config "/mimeapps.list"))
                  ;; The application is discoverable via XDG_DATA_DIRS, like a Flatpak
                  ;; export, but no update-desktop-database or application is executed.
                  (call-with-output-file (string-append applications "/"
                                                        desktop)
                    (lambda (port)
                      (format port "[Desktop Entry]
Name=Fixture
Type=Application
Exec=true %U
MimeType=~a;
" mime)))
                  (copy-file %url-file
                             (string-append applications "/"
                                            %vscode-url-desktop-entry)))
                (lambda ()
                  (with-environment-variables `(("HOME" ,root)
                                                ("XDG_CONFIG_HOME" ,config)
                                                ("XDG_CONFIG_DIRS" ,config)
                                                ("XDG_DATA_HOME" ,data)
                                                ("XDG_DATA_DIRS" ,exports)
                                                ("XDG_CURRENT_DESKTOP" "")
                                                ("LC_ALL" "C")
                                                ("LANGUAGE" "C"))
                                              (for-each (lambda (entry)
                                                          (let* ((pipe (open-pipe*
                                                                        OPEN_READ
                                                                        %gio
                                                                        "mime"
                                                                        (car
                                                                         entry)))
                                                                 (text (get-string-all
                                                                        pipe))
                                                                 (status (close-pipe
                                                                          pipe)))
                                                            (test-assert (string-append
                                                                          "GIO resolves without a MIME cache: "
                                                                          (car
                                                                           entry))
                                                                         (and (zero?
                                                                               status)

                                                                              
                                                                              (string-prefix?
                                                                               "Default application for "
                                                                               text)

                                                                              
                                                                              (string-contains
                                                                               text

                                                                               
                                                                               (string-append
                                                                                ": "

                                                                                
                                                                                (cdr
                                                                                 entry)
                                                                                "\n"))

                                                                              
                                                                              (string-contains
                                                                               text

                                                                               
                                                                               (string-append
                                                                                "Registered applications:\n\t"

                                                                                
                                                                                (cdr
                                                                                 entry)))))))
                                                        (list (cons mime
                                                                    desktop)
                                                              (cons
                                                               "x-scheme-handler/vscode"
                                                               %vscode-url-desktop-entry)))))
                (lambda ()
                  (delete-file-recursively root))))

(close-connection %store)

(test-end "xdg-policy")
