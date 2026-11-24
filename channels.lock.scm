(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "ab6a9f84e783710335a29f6591f570e5e2df143c")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "ee118ce90d55c9d80af11295f28d6f971369161c")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (commit "a6736d8030c9a14bbd0d1a66839828e66c7058d5")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      (channel
       (name 'virelith)
       (url "https://github.com/ordchaos/virelith.git")
       (branch "master")
       (commit "06c6bf19a95211a7386ea1ec59c2b8553ec2fdd7")
       (introduction
        (make-channel-introduction
         "cae11b77a64f281cc9ab45e20567e59efc37e96b"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'guix-rust-toolchain)
       (url "https://github.com/OrdChaos/guix-rust-toolchain.git")
       (branch "master")
       (commit "3e93c48e63690b83ccbb111bfec2a361653f0041")
       (introduction
        (make-channel-introduction
         "7eb3c7727b341ac671f1b7a06054a8aacc28cb52"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'bluebox)
       (url "https://codeberg.org/lapislazuli/bluebox")
       (branch "main")
       (commit "ca029acc666b290e3da793913f838687c557ad2a")))
