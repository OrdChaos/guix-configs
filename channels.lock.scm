(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "3874c8f7ec1b3edae38fb84532db0680c0b6885a")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "6b8897cd6f3223b158c070cdc9cc638279f8c337")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (commit "2f77ce5db22111c182ea9168b97f8ea23ab526c8")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      (channel
       (name 'virelith)
       (url "https://github.com/ordchaos/virelith.git")
       (branch "master")
       (commit "a30fa1de9e687507d751e60c2382558a91ee27e8")
       (introduction
        (make-channel-introduction
         "cae11b77a64f281cc9ab45e20567e59efc37e96b"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'guix-rust-toolchain)
       (url "https://github.com/OrdChaos/guix-rust-toolchain.git")
       (branch "master")
       (commit "7769fcb4d46da205da79861c51d57e9e12718fac")
       (introduction
        (make-channel-introduction
         "7eb3c7727b341ac671f1b7a06054a8aacc28cb52"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'bluebox)
       (url "https://codeberg.org/lapislazuli/bluebox")
       (branch "main")
       (commit "db72ed92aca17d4ca7b85e6bd6ee3c210c7cb2ae")))
