;;; Flatpak model 测试（docs/architecture/flatpak.md）：记录构造、
;;; fail-fast 校验（duplicate logical name / duplicate app-id /
;;; unknown remote / invalid app-id / empty branch / update policy /
;;; override policy / extra-persistence / selection unknown app /
;;; remote 校验）、selection resolver、reconcile plan 纯函数（只增
;;; 不删、runtime 不参与）、override renderer 确定性 fixture、
;;; bootstrap descriptor 生成（Url 从 record 派生、GPGKey 内嵌）。
;;;
;;; 全部纯数据——不触 flatpak CLI、不触网络。

(use-modules (guixcfg flatpak model)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "flatpak-model")

;; ── fixtures ───────────────────────────────────────────────
(define %fp-remotes
  (list (flatpak-remote
         (name 'flathub)
         (descriptor-url "https://dl.flathub.org/repo/flathub.flatpakrepo")
         (repository-url "https://dl.flathub.org/repo/")
         (comment "fixture"))
        (flatpak-remote
         (name 'internal)
         (descriptor-url "https://example.invalid/repo/internal.flatpakrepo")
         (repository-url "https://example.invalid/repo/"))))

(define %fp-commit
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

(define %fp-apps
  (list (flatpak-application
         (name 'wechat)
         (id "com.tencent.WeChat")
         (remote 'flathub)
         (branch "stable"))
        (flatpak-application
         (name 'pinned)
         (id "org.example.Pinned")
         (remote 'flathub)
         (branch "stable")
         (update-policy (list 'flatpak-commit-pin %fp-commit)))
        (flatpak-application
         (name 'unselected)
         (id "org.example.Unselected")
         (remote 'flathub)
         (branch "stable"))))

;; ── record 构造与 accessor ─────────────────────────────────
(test-assert "flatpak-remote constructible"
             (flatpak-remote? (car %fp-remotes)))
(test-equal "remote name"
            'flathub (flatpak-remote-name (car %fp-remotes)))
(test-equal "remote repository-url"
            "https://dl.flathub.org/repo/"
            (flatpak-remote-repository-url (car %fp-remotes)))
(test-equal "remote descriptor-url (bootstrap + trust authority)"
            "https://dl.flathub.org/repo/flathub.flatpakrepo"
            (flatpak-remote-descriptor-url (car %fp-remotes)))
(test-assert "flatpak-application constructible"
             (flatpak-application? (car %fp-apps)))
(test-equal "application default update-policy is track-branch"
            'track-branch
            (flatpak-application-update-policy (car %fp-apps)))
(test-equal "application default override-policy is external"
            'external
            (flatpak-application-override-policy (car %fp-apps)))
(test-equal "application default extra-persistence is empty"
            '() (flatpak-application-extra-persistence (car %fp-apps)))
(test-equal "application ref"
            "com.tencent.WeChat//stable"
            (flatpak-application-ref (car %fp-apps)))

;; ── app-id / branch / commit 校验 ──────────────────────────
(test-assert "valid app-id"
             (valid-flatpak-app-id? "com.tencent.WeChat"))
(test-assert "valid app-id with long TLD"
             (valid-flatpak-app-id? "com.github.tchx84.Flatseal"))
(test-assert "invalid app-id: single segment"
             (not (valid-flatpak-app-id? "WeChat")))
(test-assert "invalid app-id: empty segment"
             (not (valid-flatpak-app-id? "com..tencent.WeChat")))
(test-assert "invalid app-id: space"
             (not (valid-flatpak-app-id? "com.tencent WeChat")))
(test-assert "invalid app-id: slash"
             (not (valid-flatpak-app-id? "com/tencent.WeChat")))
(test-assert "invalid app-id: leading dot"
             (not (valid-flatpak-app-id? ".com.tencent")))
(test-assert "invalid app-id: empty string"
             (not (valid-flatpak-app-id? "")))

(test-assert "valid branch"
             (valid-flatpak-branch? "stable"))
(test-assert "valid branch with dots"
             (valid-flatpak-branch? "23.08"))
(test-assert "invalid branch: empty"
             (not (valid-flatpak-branch? "")))
(test-assert "invalid branch: slash"
             (not (valid-flatpak-branch? "stable/2")))
(test-assert "invalid branch: whitespace"
             (not (valid-flatpak-branch? "sta ble")))

(test-assert "valid commit: hex"
             (valid-flatpak-commit? %fp-commit))
(test-assert "invalid commit: empty string"
             (not (valid-flatpak-commit? "")))
(test-assert "invalid commit: non-hex"
             (not (valid-flatpak-commit? "xyz123")))
(test-assert "invalid commit: non-string"
             (not (valid-flatpak-commit? 42)))

;; ── update policy（显式领域语义）───────────────────────────
(test-assert "valid update-policy: track-branch"
             (valid-flatpak-update-policy? 'track-branch))
(test-assert "valid update-policy: commit pin"
             (valid-flatpak-update-policy?
              (list 'flatpak-commit-pin %fp-commit)))
(test-assert "invalid update-policy: unknown symbol"
             (not (valid-flatpak-update-policy? 'magic)))
(test-assert "invalid update-policy: pin with bad commit"
             (not (valid-flatpak-update-policy?
                   (list 'flatpak-commit-pin "nothex"))))
(test-assert "invalid update-policy: pin wrong arity"
             (not (valid-flatpak-update-policy?
                   (list 'flatpak-commit-pin %fp-commit "extra"))))
(test-equal "commit view: track-branch -> #f"
            #f (flatpak-application-commit (car %fp-apps)))
(test-equal "commit view: pinned -> hash"
            %fp-commit (flatpak-application-commit (cadr %fp-apps)))
(test-assert "pinned? view"
             (and (not (flatpak-application-pinned? (car %fp-apps)))
                  (flatpak-application-pinned? (cadr %fp-apps))))

;; ── override policy（explicit ownership）───────────────────
(test-assert "valid override-policy: external"
             (valid-flatpak-override-policy? 'external))
(test-assert "valid override-policy: managed"
             (valid-flatpak-override-policy?
              (list 'managed-overrides
                    (flatpak-override (sockets '("wayland"))))))
(test-assert "invalid override-policy: managed with non-override"
             (not (valid-flatpak-override-policy?
                   (list 'managed-overrides 42))))
(test-assert "invalid override-policy: unknown symbol"
             (not (valid-flatpak-override-policy? 'magic)))
(test-equal "managed view: external -> #f"
            #f (flatpak-application-managed-overrides (car %fp-apps)))
(test-equal "managed view: managed -> override record"
            '("wayland")
            (flatpak-override-sockets
             (flatpak-application-managed-overrides
              (flatpak-application
               (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
               (override-policy
                (list 'managed-overrides
                      (flatpak-override (sockets '("wayland")))))))))

;; ── override 校验（record 内部字段）────────────────────────
(test-assert "valid bus policy"
             (valid-flatpak-application?
              (flatpak-application
               (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
               (override-policy
                (list 'managed-overrides
                      (flatpak-override
                       (session-bus '("org.freedesktop.secrets=talk"))
                       (system-bus '("org.freedesktop.UPower=own"))))))
              '(flathub)))
(test-assert "invalid bus policy: no assignment"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (override-policy
                     (list 'managed-overrides
                           (flatpak-override
                            (session-bus '("org.freedesktop.secrets"))))))
                   '(flathub))))
(test-assert "invalid environment entry: no assignment"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (override-policy
                     (list 'managed-overrides
                           (flatpak-override
                            (environment '("NOVAR"))))))
                   '(flathub))))

;; ── extra-persistence 校验 ─────────────────────────────────
(test-assert "valid extra-persistence: empty"
             (valid-flatpak-application?
              (flatpak-application (name 'a) (id "com.x.A")
                                   (remote 'flathub) (branch "stable"))
              '(flathub)))
(test-assert "valid extra-persistence: pairs"
             (valid-flatpak-application?
              (flatpak-application
               (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
               (extra-persistence '((".local/share/wechat" "wechat/share"))))
              '(flathub)))
(test-assert "invalid extra-persistence: absolute consumer"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (extra-persistence '(("/abs" "wechat/share"))))
                   '(flathub))))
(test-assert "invalid extra-persistence: backing escape"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (extra-persistence '((".local/share/wechat" "../x"))))
                   '(flathub))))

;; ── remote 校验 ────────────────────────────────────────────
(test-assert "valid remote"
             (valid-flatpak-remote? (car %fp-remotes)))
(test-assert "invalid remote: empty repository-url"
             (not (valid-flatpak-remote?
                   (flatpak-remote
                    (name 'x)
                    (descriptor-url "https://e/foo.flatpakrepo")
                    (repository-url "")))))
(test-assert "invalid remote: empty descriptor-url"
             (not (valid-flatpak-remote?
                   (flatpak-remote
                    (name 'x)
                    (descriptor-url "")
                    (repository-url "https://e/")))))

;; ── application 校验（remote 已知性）───────────────────────
(test-assert "valid application"
             (valid-flatpak-application? (car %fp-apps)
                                         (map flatpak-remote-name %fp-remotes)))
(test-assert "invalid application: unknown remote"
             (not (valid-flatpak-application? (car %fp-apps) '(other))))
(test-assert "invalid application: empty branch"
             (not (valid-flatpak-application?
                   (flatpak-application (name 'x) (id "com.x.X")
                                        (remote 'flathub) (branch ""))
                   '(flathub))))
(test-assert "invalid application: bad update-policy"
             (not (valid-flatpak-application?
                   (flatpak-application (name 'x) (id "com.x.X")
                                        (remote 'flathub) (branch "stable")
                                        (update-policy 'magic))
                   '(flathub))))

;; ── catalog / selection fail-fast ──────────────────────────
(test-assert "valid catalog passes"
             (validate-flatpak-catalog! %fp-remotes %fp-apps))
(test-error "catalog duplicate logical name" #t
            (validate-flatpak-catalog!
             %fp-remotes
             (list (car %fp-apps)
                   (flatpak-application (name 'wechat) (id "com.x.Other")
                                        (remote 'flathub) (branch "stable")))))
(test-error "catalog duplicate app-id" #t
            (validate-flatpak-catalog!
             %fp-remotes
             (list (car %fp-apps)
                   (flatpak-application (name 'other)
                                        (id "com.tencent.WeChat")
                                        (remote 'flathub) (branch "stable")))))
(test-error "catalog duplicate remote name" #t
            (validate-flatpak-catalog!
             (list (flatpak-remote (name 'flathub)
                                   (descriptor-url "https://a/foo.flatpakrepo")
                                   (repository-url "https://a/"))
                   (flatpak-remote (name 'flathub)
                                   (descriptor-url "https://b/foo.flatpakrepo")
                                   (repository-url "https://b/")))
             %fp-apps))
(test-error "catalog invalid app" #t
            (validate-flatpak-catalog!
             %fp-remotes
             (list (flatpak-application (name 'bad) (id "no-dot")
                                        (remote 'flathub) (branch "stable")))))
(test-error "catalog unknown remote reference" #t
            (validate-flatpak-catalog!
             %fp-remotes
             (list (flatpak-application (name 'x) (id "com.x.X")
                                        (remote 'nope) (branch "stable")))))

(test-assert "valid selection passes"
             (validate-flatpak-selection! '(wechat) %fp-apps))
(test-assert "empty selection passes"
             (validate-flatpak-selection! '() %fp-apps))
(test-error "selection unknown logical name" #t
            (validate-flatpak-selection! '(ghost) %fp-apps))

;; ── selection resolver ─────────────────────────────────────
(test-equal "selection resolves in catalog order"
            (list (car %fp-apps) (cadr %fp-apps))
            (flatpak-select-applications '(pinned wechat) %fp-apps))
(test-equal "selection empty -> empty"
            '() (flatpak-select-applications '() %fp-apps))
(test-error "selection resolver unknown name" #t
            (flatpak-select-applications '(ghost) %fp-apps))

;; ── reconcile plan（纯函数，只增不删）──────────────────────
(test-equal "plan: missing selected -> install"
            (list (car %fp-apps) (cadr %fp-apps))
            (flatpak-reconcile-plan
             (flatpak-select-applications '(wechat pinned) %fp-apps)
             '()))
(test-equal "plan: already installed -> no-op"
            '()
            (flatpak-reconcile-plan
             (flatpak-select-applications '(wechat pinned) %fp-apps)
             '("com.tencent.WeChat" "org.example.Pinned")))
(test-equal "plan: unmanaged installed app untouched"
            '("com.tencent.WeChat")
            (map flatpak-application-id
                 (flatpak-reconcile-plan
                  (flatpak-select-applications '(wechat) %fp-apps)
                  '("org.other.Unmanaged" "org.freedesktop.Platform"))))
(test-equal "plan: runtime refs never enter comparison"
            '()
            (flatpak-reconcile-plan
             (flatpak-select-applications '() %fp-apps)
             '("org.freedesktop.Platform" "org.freedesktop.Platform.GL.default")))
(test-equal "plan: unselected catalog app never planned"
            '()
            (map flatpak-application-id
                 (flatpak-reconcile-plan
                  (flatpak-select-applications '(wechat) %fp-apps)
                  '("com.tencent.WeChat"))))

;; ── override renderer（确定性 fixture）─────────────────────
(test-equal "renderer deterministic complete-file"
            "[Context]\nsockets=wayland;fallback-x11;\nfilesystems=xdg-download:ro;!host;\nenvironment=LC_ALL=zh_CN.UTF-8;\n\n[Session Bus Policy]\norg.freedesktop.secrets=talk\n\n[System Bus Policy]\norg.freedesktop.UPower=talk\n"
            (flatpak-render-override-file
             (flatpak-override
              (sockets '("wayland" "fallback-x11"))
              (filesystems '("xdg-download:ro" "!host"))
              (environment '("LC_ALL=zh_CN.UTF-8"))
              (session-bus '("org.freedesktop.secrets=talk"))
              (system-bus '("org.freedesktop.UPower=talk")))))
(test-equal "renderer field order fixed (shared before sockets)"
            "[Context]\nshared=network;\nsockets=wayland;\n"
            (flatpak-render-override-file
             (flatpak-override
              (sockets '("wayland"))
              (shared '("network")))))
(test-equal "renderer list order = declaration order"
            "[Context]\ndevices=dri;kvm;\n"
            (flatpak-render-override-file
             (flatpak-override (devices '("dri" "kvm")))))
(test-equal "renderer escapes backslash and semicolon"
            "[Context]\nfilesystems=a\\\\b;a\\;b;\n"
            (flatpak-render-override-file
             (flatpak-override (filesystems '("a\\b" "a;b")))))
(test-equal "renderer empty override -> empty string"
            ""
            (flatpak-render-override-file (flatpak-override)))
(test-equal "renderer session bus only"
            "[Session Bus Policy]\norg.freedesktop.secrets=talk\n"
            (flatpak-render-override-file
             (flatpak-override
              (session-bus '("org.freedesktop.secrets=talk")))))

(test-end "flatpak-model")
