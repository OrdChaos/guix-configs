(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "16b1d06d61cc68148b021b305a9638bf102dfd76")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "c0192e90a52cafb4d33b04734cbe9bbedd703a04")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (commit "1f35f0e393dc3af2f1643ac3166e4075c5a85cf3")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      (channel
       (name 'virelith)
       (url "https://github.com/ordchaos/virelith.git")
       (branch "master")
       (commit "4e58e182e84080b318aca4bcac426fec55068dbe")
       (introduction
        (make-channel-introduction
         "cae11b77a64f281cc9ab45e20567e59efc37e96b"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'guix-rust-toolchain)
       (url "https://github.com/OrdChaos/guix-rust-toolchain.git")
       (branch "master")
       (commit "81152d239ca129f7dda4a258f214371d0b008d9e")
       (introduction
        (make-channel-introduction
         "7eb3c7727b341ac671f1b7a06054a8aacc28cb52"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'bluebox)
       (url "https://codeberg.org/lapislazuli/bluebox")
       (branch "main")
       (commit "a5b2168123bcc236f79cbb4f1c5d4cf5412ee31d")))
