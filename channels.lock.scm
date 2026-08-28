(list (channel
       (name 'guix)
       (url "https://codeberg.org/guix/guix.git")
       (branch "master")
       (commit "df854574b0e2ec021dcd94cd3784b51c2ba7e4c2")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "caa8c0b4646b993537be13c9bc819b3df68ab9b2")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'rosenthal)
       (url "https://codeberg.org/hako/rosenthal.git")
       (branch "trunk")
       (commit "21391bab6e38561488bd807493da1035a85c24cb")
       (introduction
        (make-channel-introduction
         "7677db76330121a901604dfbad19077893865f35"
         (openpgp-fingerprint
          "13E7 6CD6 E649 C28C 3385  4DF5 5E5A A665 6149 17F7"))))
      (channel
       (name 'virelith)
       (url "https://github.com/ordchaos/virelith.git")
       (branch "master")
       (commit "aac377d844c62efdf55fafa15a3c0dd6f434eeb4")
       (introduction
        (make-channel-introduction
         "cae11b77a64f281cc9ab45e20567e59efc37e96b"
         (openpgp-fingerprint
          "FF0F 1FE0 A176 071F 0E39  A94D FF93 E1DA E089 7EDE"))))
      (channel
       (name 'saayix)
       (url "https://codeberg.org/look/saayix")
       (branch "main")
       (commit "663966eb6d9c491174dfd67d2eadf1fca3f1577b")
       (introduction
        (make-channel-introduction
         "12540f593092e9a177eb8a974a57bb4892327752"
         (openpgp-fingerprint
          "3FFA 7335 973E 0A49 47FC  0A8C 38D5 96BE 07D3 34AB"))))
      (channel
       (name 'noctalia)
       (url "https://github.com/noctalia-dev/noctalia")
       (branch "main")
       (commit "67addbd529cfd9db30c9d0ee6e08d5f6836c9e1a")))
