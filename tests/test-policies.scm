;;; Storage policy lookup tests.

(use-modules (guixcfg storage model)
             (guixcfg storage policies)
             (guixcfg system deploy)
             (srfi srfi-1)
             (srfi srfi-64))

(test-begin "storage-policies")

(test-eq "vm policy by string"
         'vm
         (host-storage-policy-name (storage-policy-by-name "vm")))

(test-eq "Lenovo policy by symbol"
         'lenovo-legion-y7000p
         (host-storage-policy-name
          (storage-policy-by-name 'lenovo-legion-y7000p)))

(test-eq "unknown policy" #f (storage-policy-by-name "unknown"))

(test-equal "storage policy registry exactly matches deployable Host IDs"
            (host-ids-in-directory "modules/guixcfg/hosts")
            (sort (map (lambda (policy)
                         (symbol->string (host-storage-policy-name policy)))
                       %storage-policies)
                  string<?))

(test-assert "every policy lookup returns a policy named for that Host ID"
             (every (lambda (host-id)
                      (let ((policy (storage-policy-by-name host-id)))
                        (and policy
                             (string=? host-id
                                       (symbol->string
                                        (host-storage-policy-name policy))))))
                    (host-ids-in-directory "modules/guixcfg/hosts")))

(test-end)
