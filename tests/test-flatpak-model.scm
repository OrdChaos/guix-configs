;;; Flatpak model 测试（docs/architecture/flatpak.md）：记录构造、
;;; fail-fast 校验（duplicate logical name / duplicate app-id /
;;; unknown remote / invalid app-id / empty branch / invalid commit /
;;; selection unknown app / remote location 校验）、selection
;;; resolver、reconcile plan 纯函数（只增不删、runtime 不参与）、
;;; override renderer 确定性 fixture。
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
         (location "https://dl.flathub.org/repo/flathub.flatpakrepo")
         (repository-url "https://dl.flathub.org/repo/")
         (comment "fixture"))
        (flatpak-remote
         (name 'internal)
         (location "https://example.invalid/repo")
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
         (commit %fp-commit))
        (flatpak-application
         (name 'unselected)
         (id "org.example.Unselected")
         (remote 'flathub)
         (branch "stable"))))

;; ── record 构造与 accessor ─────────────────────────────────
(test-assert "flatpak-remote constructible"
             (flatpak-remote? (car %fp-remotes)))
(test-equal "remote name" 'flathub (flatpak-remote-name (car %fp-remotes)))
(test-equal "remote location/repository-url are independent semantics"
            "https://dl.flathub.org/repo/flathub.flatpakrepo"
            (flatpak-remote-location (car %fp-remotes)))
(test-equal "remote repository-url"
            "https://dl.flathub.org/repo/"
            (flatpak-remote-repository-url (car %fp-remotes)))
(test-assert "flatpak-application constructible"
             (flatpak-application? (car %fp-apps)))
(test-equal "application default commit #f (branch tracking)"
            #f (flatpak-application-commit (car %fp-apps)))
(test-equal "application default overrides #f (user-owned)"
            #f (flatpak-application-overrides (car %fp-apps)))
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

(test-assert "valid commit: #f"
             (valid-flatpak-commit? #f))
(test-assert "valid commit: hex"
             (valid-flatpak-commit? %fp-commit))
(test-assert "invalid commit: empty string"
             (not (valid-flatpak-commit? "")))
(test-assert "invalid commit: non-hex"
             (not (valid-flatpak-commit? "xyz123")))
(test-assert "invalid commit: non-string"
             (not (valid-flatpak-commit? 42)))

;; ── remote 校验 ────────────────────────────────────────────
(test-assert "valid remote"
             (valid-flatpak-remote? (car %fp-remotes)))
(test-assert "invalid remote: empty location"
             (not (valid-flatpak-remote?
                   (flatpak-remote
                    (name 'x) (location "") (repository-url "https://e/")))))
(test-assert "invalid remote: empty repository-url"
             (not (valid-flatpak-remote?
                   (flatpak-remote
                    (name 'x) (location "https://e/") (repository-url "")))))

;; ── override 校验 ──────────────────────────────────────────
(test-assert "override #f valid"
             (valid-flatpak-application?
              (flatpak-application (name 'a) (id "com.x.A") (remote 'flathub)
                                   (branch "stable"))
              '(flathub)))
(test-assert "valid bus policy"
             (valid-flatpak-application?
              (flatpak-application
               (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
               (overrides (flatpak-override
                           (session-bus '("org.freedesktop.secrets=talk"))
                           (system-bus '("org.freedesktop.UPower=own")))))
              '(flathub)))
(test-assert "invalid bus policy: no assignment"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (overrides (flatpak-override
                                (session-bus '("org.freedesktop.secrets")))))
                   '(flathub))))
(test-assert "invalid bus policy: unknown value"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (overrides (flatpak-override
                                (system-bus '("org.foo=talkalot")))))
                   '(flathub))))
(test-assert "invalid environment entry: no assignment"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (overrides (flatpak-override
                                (environment '("NOVAR")))))
                   '(flathub))))
(test-assert "invalid environment entry: newline"
             (not (valid-flatpak-application?
                   (flatpak-application
                    (name 'a) (id "com.x.A") (remote 'flathub) (branch "stable")
                    (overrides (flatpak-override
                                (environment '("A=1\nB=2")))))
                   '(flathub))))

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
(test-assert "invalid application: bad commit"
             (not (valid-flatpak-application?
                   (flatpak-application (name 'x) (id "com.x.X")
                                        (remote 'flathub) (branch "stable")
                                        (commit "nothex"))
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
             (list (flatpak-remote (name 'flathub) (location "https://a/")
                                   (repository-url "https://a/"))
                   (flatpak-remote (name 'flathub) (location "https://b/")
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
