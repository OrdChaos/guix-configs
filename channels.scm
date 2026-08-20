;;; 频道集合：描述上游来源，不固定版本（版本固定在 channels.lock.scm）。
;;;
;;; 日常使用一律走锁文件，保证可重现：
;;;   guix time-machine -C channels.lock.scm -- <command>
;;;
;;; 需要升级上游时，重建锁（联网，会拉到当时的最新 master）：
;;;   guix time-machine -C channels.scm -- describe -f channels > channels.lock.scm
;;; 重建后先用新锁跑一遍 tests/run-tests.scm 和 system build，
;;; 确认无误再把 channels.lock.scm 一起提交。
;;; 见 docs/operations/reconfigure.md。

(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5"))))
      ;; UKI 工具链（systemd-stub、ukify；没有 systemd-boot，见 docs/architecture/boot.md）
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      ;; 自有频道
      (channel
       (name 'virelith)
       (url "https://github.com/ordchaos/virelith.git")
       (branch "master")
       (introduction
        (make-channel-introduction
         "cae11b77a64f281cc9ab45e20567e59efc37e96b"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'saayix)
       (branch "main")
       (url "https://codeberg.org/look/saayix")
       (introduction
        (make-channel-introduction
         "12540f593092e9a177eb8a974a57bb4892327752"
         (openpgp-fingerprint
          "3FFA 7335 973E 0A49 47FC  0A8C 38D5 96BE 07D3 34AB")))))
