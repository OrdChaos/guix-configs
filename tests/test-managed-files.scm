;;; managed-files 投影原语的行为测试。

(use-modules (guix build utils)
             (guix gexp)
             (guixcfg home managed-files)
             (guixcfg utils managed-file)
             (ice-9 textual-ports)
             (srfi srfi-64))

(test-begin "managed-files")

(define (write-text path text)
  (call-with-output-file path
    (lambda (port)
      (display text port))))

(let* ((dir (mkdtemp "/tmp/guixcfg-managed-files-XXXXXX"))
       (source (string-append dir "/source"))
       (target (string-append dir "/home/.local/share/app/state.conf"))
       (sibling (string-append dir "/home/.local/share/app/user.conf")))
  (dynamic-wind
   (lambda () #t)
   (lambda ()
     (write-text source "first\n")

     (install-managed-file! target source 'file)
     (test-equal "file is installed" "first\n"
                 (call-with-input-file target get-string-all))
     (test-equal "file mode is 0644" #o644
                 (stat:perms (stat target)))

     (let ((inode (stat:ino (stat target))))
       (install-managed-file! target source 'file)
       (test-equal "same content is a no-op" inode
                   (stat:ino (stat target))))

     (write-text source "second\n")
     (install-managed-file! target source 'file)
     (test-equal "changed content is replaced" "second\n"
                 (call-with-input-file target get-string-all))

     (write-text sibling "user\n")
     (install-managed-file! target source 'file)
     (test-equal "unlisted sibling is preserved" "user\n"
                 (call-with-input-file sibling get-string-all))

     (test-assert "directory collision fails closed"
                  (let ((bad (string-append dir "/home/.local/share/app/bad")))
                    (mkdir-p bad)
                    (catch #t
                      (lambda ()
                        (install-managed-file! bad source 'file)
                        #f)
                      (lambda args #t))))

     (let* ((link-source (string-append dir "/link-source"))
            (link-target (string-append dir "/home/.local/share/app/link")))
       (write-text link-source "linked\n")
       (install-managed-file! link-target link-source 'symlink)
       (test-equal "symlink points at source" link-source
                   (readlink link-target))
       (install-managed-file! link-target link-source 'symlink)
       (test-equal "symlink is idempotent" link-source
                   (readlink link-target))
       (test-assert "regular file at symlink target fails closed"
                    (let ((bad (string-append dir "/home/.local/share/app/bad-link")))
                      (write-text bad "not a link\n")
                      (catch #t
                        (lambda ()
                          (install-managed-file! bad link-source 'symlink)
                          #f)
                        (lambda args #t))))))
   (lambda ()
     (delete-file-recursively dir))))

(test-assert "duplicate managed-file targets fail closed"
  (catch #t
    (lambda ()
      (managed-files-activation
       (list (managed-file (name 'a)
                           (target ".local/share/app/same")
                           (source (plain-file "a" "a")))
             (managed-file (name 'b)
                           (target ".local/share/app/same")
                           (source (plain-file "b" "b")))))
      #f)
    (lambda args #t)))

(test-end)
