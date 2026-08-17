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

;; 旧版 lsblk：mountpoint 是单个字符串而不是 mountpoints 数组。
(define %legacy-lsblk-json
  "{\"blockdevices\": [
      {\"name\": \"/dev/sr0\", \"path\": \"/dev/sr0\", \"type\": \"rom\",
       \"size\": 1500000000, \"mountpoint\": \"/run/install\"}
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
            
            (let ((rom (parse-lsblk-json %legacy-lsblk-json)))
              (test-equal "legacy single-string mountpoint normalized"
                          '("/run/install") (device-node-mountpoints rom))
              (test-assert "LiveCD media recognized as mounted" (device-node-mounted? rom))))

(test-end)
