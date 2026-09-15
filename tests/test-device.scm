;;; device.scm 纯解析函数的单元测试。由 tests/run-tests.scm 加载运行。

(use-modules (guixcfg storage device)
             (srfi srfi-64))

;; 一块有两分区的整盘：ESP 未挂载，系统分区挂载在 /mnt。
(define %mounted-disk-json
  "{\"blockdevices\": [
      {\"name\": \"/dev/vda\", \"path\": \"/dev/vda\", \"type\": \"disk\",
       \"size\": 26843545600, \"mountpoints\": [null],
       \"children\": [
          {\"name\": \"/dev/vda1\", \"path\": \"/dev/vda1\", \"type\": \"part\",
           \"size\": 2147483648, \"mountpoints\": [null]},
          {\"name\": \"/dev/vda2\", \"path\": \"/dev/vda2\", \"type\": \"part\",
           \"size\": 24700000000, \"mountpoints\": [\"/mnt\"]}
       ]}
   ]}")

;; 一块完全未挂载的整盘。
(define %clean-disk-json
  "{\"blockdevices\": [
      {\"name\": \"/dev/vdb\", \"path\": \"/dev/vdb\", \"type\": \"disk\",
       \"size\": 26843545600, \"mountpoints\": [null]}
   ]}")

;; 一个分区节点。
(define %partition-json
  "{\"blockdevices\": [
      {\"name\": \"/dev/vdb1\", \"path\": \"/dev/vdb1\", \"type\": \"part\",
       \"size\": 2147483648, \"mountpoints\": [\"/boot\"]}
   ]}")

;; LiveCD 介质（rom，挂载在 /run/install）。
(define %livecd-rom-json
  "{\"blockdevices\": [
      {\"name\": \"/dev/sr0\", \"path\": \"/dev/sr0\", \"type\": \"rom\",
       \"size\": 1500000000, \"mountpoints\": [\"/run/install\"]}
   ]}")

;; 分区下还有 dm-crypt 后代；递归挂载检测不能只看第一层 children。
(define %nested-mounted-json
  "{\"blockdevices\": [
      {\"path\": \"/dev/vdc\", \"type\": \"disk\", \"size\": 1,
       \"mountpoints\": [null], \"children\": [
         {\"path\": \"/dev/vdc2\", \"type\": \"part\", \"size\": 1,
          \"mountpoints\": [null], \"children\": [
            {\"path\": \"/dev/mapper/test\", \"type\": \"crypt\", \"size\": 1,
             \"mountpoints\": [\"/mnt\"]}
          ]}
       ]}
    ]}")

(test-begin "storage-device")

(test-group "parse-lsblk-json"
            (let ((disk (parse-lsblk-json %mounted-disk-json)))
              (test-equal "recognizes whole-disk type" "disk" (device-node-type disk))
              (test-equal "size is integer (-b)" 26843545600 (device-node-size disk))
              (test-equal "parses two child partitions" 2 (length (device-node-children disk)))
              (test-assert "whole disk itself not mounted" (not (device-node-mounted? disk)))
              (test-assert "child partition vda2 mounted"
                           (device-node-mounted?
                            (cadr (device-node-children disk)))))
            
            (let ((disk (parse-lsblk-json %clean-disk-json)))
              (test-assert "clean disk unmounted and childless"
                           (and (not (device-node-mounted? disk))
                                (null? (device-node-children disk)))))
            
            (let ((part (parse-lsblk-json %partition-json)))
              (test-equal "recognizes partition type" "part" (device-node-type part))
              (test-assert "partition mounted" (device-node-mounted? part)))
            
             (let ((rom (parse-lsblk-json %livecd-rom-json)))
               (test-assert "LiveCD media recognized as mounted" (device-node-mounted? rom))))

(test-assert "mounted descendants are detected recursively"
             (device-node-tree-mounted?
              (parse-lsblk-json %nested-mounted-json)))

;; target-partition-path derives NVMe names and verifies ownership through
;; lsblk before returning a path.
(define %fake-bin
  (string-append "/tmp/guixcfg-test-device-bin-"
                 (number->string (getpid))))
(define %original-path (getenv "PATH"))
(unless (file-exists? %fake-bin)
  (mkdir %fake-bin))
(call-with-output-file (string-append %fake-bin "/lsblk")
  (lambda (p)
    (display "#!/bin/sh\n" p)
    (display "field=$2; dev=$3\n" p)
    (display "case \"$field:$dev\" in\n" p)
     (display "TYPE:/dev/nvme0n1|TYPE:/dev/nvme1n1) printf 'disk\\n' ;;\n" p)
     (display "TYPE:/dev/nvme0n1p2|TYPE:/dev/nvme1n1p2) printf 'part\\n' ;;\n" p)
     (display "PARTLABEL:/dev/nvme0n1p2|PARTLABEL:/dev/nvme1n1p2) printf 'system\\n' ;;\n" p)
     (display "PKNAME:/dev/nvme0n1p2|PKNAME:/dev/nvme1n1p2) printf 'nvme0n1\\n' ;;\n" p)
    (display "esac\n" p)))
(chmod (string-append %fake-bin "/lsblk") #o755)
(setenv "PATH" (string-append %fake-bin ":" %original-path))

(test-equal "partition path is derived from and owned by target disk"
            "/dev/nvme0n1p2"
            (target-partition-path "/dev/nvme0n1" 2))
(test-error "partition owned by another disk is rejected" #t
            (target-partition-path "/dev/nvme1n1" 2))

(setenv "PATH" %original-path)
(false-if-exception (delete-file (string-append %fake-bin "/lsblk")))
(false-if-exception (rmdir %fake-bin))

(test-end)
