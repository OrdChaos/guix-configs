;;; 频道锁：固定实际使用的 channel commit 和 introduction。
;;; 所有构建和部署均通过：guix time-machine -C channels.lock.scm -- ...
;;; 更新流程见 docs/deployment.md 第 7.4 节（显式更新，构建检查后再提交）。

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (commit
         "726095a4c8b7f12b8fa04eb5f4e1d538b853014e")
        (introduction
         (make-channel-introduction
          "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
        (name 'nonguix)
        (url "https://gitlab.com/nonguix/nonguix")
        (branch "master")
        (commit
         "7b7b2c47f9c205ad89ddf54293e7756e797f8980")
        (introduction
         (make-channel-introduction
          "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
          (openpgp-fingerprint
           "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5")))))
