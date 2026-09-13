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

(test-eq "laptop policy by symbol"
         'laptop
         (host-storage-policy-name (storage-policy-by-name 'laptop)))

(test-eq "unknown policy" #f (storage-policy-by-name "unknown"))

(test-assert "every deployable host has a storage policy"
             (every storage-policy-by-name
                    (host-ids-in-directory "modules/guixcfg/hosts")))

(test-end)
