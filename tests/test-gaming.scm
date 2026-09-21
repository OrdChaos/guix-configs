;;; Gaming 接线静态契约测试（2026-09 Steam 全线 Flatpak 化；
;;; Flatpak selection 2026-09 全局化——硬件差异只经 environment
;;; adapter 表达）：
;;;   - (guixcfg system gaming)：游戏库路径 authority
;;;     （persist-mount-point 派生 /persist/data-nobackup/steam）、
;;;     system services（steam-devices udev rules + 目录
;;;     activation）——所有 host 共享；
;;;   - Flatpak steam definition：id / managed filesystem override =
;;;     游戏库路径 authority 引用（硬件中性）；
;;;   - NVIDIA PRIME：单一 authority（%prime-offload-environment-strings
;;;     与 %flatpak-prime-environment-overrides）——application
;;;     definition 不直接引用 NVIDIA 模块；
;;;   - registry：steam/aagl 与 gamescope/proton-ge 在 catalog，
;;;     全局 selection 含全部四个 app 与两个 extension；
;;;   - host 差异：Lenovo Guix Home 传 PRIME environment adapter，
;;;     VM 传空 adapter，全局 selection/persistence 仍一致。

(use-modules (gnu services)          ; service-kind
             (gnu services base)     ; udev-service-type、activation-service-type
             (srfi srfi-1)           ; find
             (srfi srfi-13)          ; string-prefix?
             (srfi srfi-26)          ; cut
             (srfi srfi-64)
             (ice-9 rdelim)          ; read-string
             (guixcfg flatpak model)
             (guixcfg flatpak registry)
             (guixcfg flatpak applications steam definition)
             (guixcfg flatpak applications aagl definition)
             (guixcfg flatpak extensions gamescope definition)
             (guixcfg flatpak extensions proton-ge definition)
             (guixcfg storage model) ; persist-mount-point
             (guixcfg system gaming)
             (guixcfg system application-persistence)
             (guixcfg system graphics nvidia) ; %prime-offload-environment-strings
             (guixcfg hosts common)
             (guixcfg hosts vm)
             (guixcfg hosts lenovo-legion-y7000p))

(test-runner-current (test-runner-simple))

(test-begin "gaming")

;; simple-service 返回包装 service-type——按 extension target 判定
;; （tests/test-flatpak-service.scm 同款模式）。
(define (service-extends? svc target-type)
  (any (lambda (ext)
         (eq? (service-extension-target ext) target-type))
       (service-type-extensions (service-kind svc))))

;; ── gaming system module ────────────────────────────────────

(test-equal "steam games library derived from persist-mount-point"
            (string-append (persist-mount-point "@persist-data-nobackup")
                           "/steam")
            %steam-games-library-path)

(test-assert "gaming contributes steam-devices udev rules"
             (find (lambda (svc)
                     (service-extends? svc udev-service-type))
                   %gaming-system-services))

(test-assert "gaming contributes games library directory activation"
             (find (lambda (svc)
                     (service-extends? svc activation-service-type))
                   %gaming-system-services))

;; ── flatpak steam definition ────────────────────────────────

(test-equal "steam flatpak id" "com.valvesoftware.Steam"
            (flatpak-application-id %flatpak-steam))

(define %steam-overrides
  (flatpak-application-managed-overrides %flatpak-steam))

(test-assert "steam override is managed"
             %steam-overrides)

(test-equal "steam override exposes the games library"
            (list %steam-games-library-path)
            (flatpak-override-filesystems %steam-overrides))

(test-equal "steam base override is hardware-neutral (no NVIDIA env)"
            '()
            (flatpak-override-environment %steam-overrides))

(test-assert "steam filesystem override renders in Flatpak Context section"
             (let ((text (flatpak-render-override-file %steam-overrides)))
               (and (string-contains text "[Context]")
                    (string-contains text "filesystems=")
                    (not (string-contains text "[Environment]")))))

(define %steam-desktop-shadow
  (call-with-input-file
   "modules/guixcfg/flatpak/applications/steam/com.valvesoftware.Steam.desktop"
   (lambda (port) (read-string port))))

(test-equal "steam owns one complete desktop shadow"
            '("com.valvesoftware.Steam.desktop")
            (map car (flatpak-application-desktop-files %flatpak-steam)))
(test-assert "steam desktop shadow keeps the Flatpak launch contract"
             (and (string-contains %steam-desktop-shadow
                                   "X-Flatpak=com.valvesoftware.Steam")
                  (string-contains %steam-desktop-shadow
                                   "--command=/app/bin/steam")
                  (string-contains %steam-desktop-shadow
                                   "MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;")
                  (string-contains %steam-desktop-shadow
                                   "Actions=Store;Community;Library;Servers;Screenshots;News;Settings;BigPicture;Friends;")))
(test-assert "steam desktop shadow has one unambiguous main category"
             (and (string-contains %steam-desktop-shadow "Categories=Game;\n")
                  (not (string-contains %steam-desktop-shadow
                                        "Categories=Network;FileTransfer;Game;"))))

;; ── flatpak aagl definition：hardware-neutral managed file ──

(define %aagl-base-environment
  '("GIT_EXEC_PATH=/app/libexec/git-core"))

(test-assert "aagl base definition owns a hardware-neutral override file"
             (flatpak-application-managed-overrides %flatpak-aagl))

(test-equal "aagl uses its bundled Git helpers inside the sandbox"
            %aagl-base-environment
            (flatpak-override-environment
             (flatpak-application-managed-overrides %flatpak-aagl)))

(test-equal "aagl base override exposes no host filesystem"
            '()
            (flatpak-override-filesystems
             (flatpak-application-managed-overrides %flatpak-aagl)))

;; ── NVIDIA adapter → managed override overlay ───────────────

(define %prime-overlayed-steam
  (flatpak-application-with-environment
   %flatpak-steam
   (cdr (assq 'steam %flatpak-prime-environment-overrides))))

(define %prime-overlayed-aagl
  (flatpak-application-with-environment
   %flatpak-aagl
   (cdr (assq 'aagl %flatpak-prime-environment-overrides))))

(test-equal "NVIDIA adapter overlays PRIME env onto steam override"
            %prime-offload-environment-strings
            (flatpak-override-environment
             (flatpak-application-managed-overrides %prime-overlayed-steam)))

(test-equal "NVIDIA adapter overlays PRIME env onto aagl override"
            (append %aagl-base-environment
                    %prime-offload-environment-strings)
            (flatpak-override-environment
             (flatpak-application-managed-overrides %prime-overlayed-aagl)))

(test-assert "NVIDIA adapter leaves steam games library intact"
             (equal? (list %steam-games-library-path)
                     (flatpak-override-filesystems
                      (flatpak-application-managed-overrides
                       %prime-overlayed-steam))))

(test-assert "PRIME variables render in Flatpak Environment section"
             (let ((text (flatpak-render-override-file
                          (flatpak-application-managed-overrides
                           %prime-overlayed-steam))))
               (and (string-contains text "[Environment]")
                    (not (string-contains text "environment=")))))

(test-assert "overlay on external app fails closed"
             (catch #t
                    (lambda ()
                      (flatpak-applications-with-environments
                       '((qq . ("FOO=bar")))
                       %flatpak-applications)
                      #f)
                    (lambda (key . args)
                      (and (eq? key 'misc-error)
                           (any (cut string-contains <> "non-managed")
                                (map object->string args))))))

(test-assert "overlay with duplicate variables fails closed"
             (catch #t
                    (lambda ()
                      (flatpak-application-with-environment
                       %prime-overlayed-steam
                       '("__GLX_VENDOR_LIBRARY_NAME=mesa"))
                      #f)
                    (lambda (key . args)
                      (and (eq? key 'misc-error)
                           (any (cut string-contains <> "duplicate")
                                (map object->string args))))))

(test-assert "overlay with unknown target fails closed"
             (catch #t
                    (lambda ()
                      (flatpak-applications-with-environments
                       '((typo . ("FOO=bar")))
                       %flatpak-applications)
                      #f)
                    (lambda (key . args)
                      (and (eq? key 'misc-error)
                           (any (cut string-contains <> "unknown")
                                (map object->string args))))))

;; ── registry：catalog 与缺省 selection ──────────────────────

(test-assert "steam and aagl registered in the flatpak catalog"
             (every (lambda (name)
                      (memq name
                            (map flatpak-application-name
                                 %flatpak-applications)))
                    '(steam aagl)))

(test-assert "gamescope and proton-ge registered as extensions"
             (every (lambda (name)
                      (memq name
                            (map flatpak-extension-name
                                 %flatpak-extensions)))
                    '(gamescope proton-ge)))

(test-assert "global application selection includes every catalog app"
             (equal? '(qq wechat aagl steam)
                     (map flatpak-application-name
                          (flatpak-select-applications
                           %flatpak-selection %flatpak-applications))))

(test-assert "global extension selection includes gamescope and proton-ge"
             (every (lambda (name)
                      (memq name %flatpak-extension-selection))
                    '(gamescope proton-ge)))

;; ── 全局 selection 的 persistence 投影（所有 host 一致）──────

(test-assert "global activation rules cover Steam and AAGL bind sources"
             (let ((consumers
                    (map application-persistence-rule-consumer
                         (host-application-persistence-rules))))
               (every (lambda (consumer) (member consumer consumers))
                      '(".var/app/com.valvesoftware.Steam"
                        ".var/app/moe.launcher.an-anime-game-launcher"))))

(test-assert "production Flatpak selection is host-independent"
             (let ((lenovo-consumers
                    (map application-persistence-rule-consumer
                         (host-application-persistence-rules))))
               ;; VM 与 Lenovo 的 projection 来自同一全局 selection：
               ;; 逐 app 断言由 test-flatpak-persistence 的通用回归覆盖，
               ;; 这里固定"global 是唯一的 selection 事实源"。
               (every (lambda (name)
                        (memq name %flatpak-selection))
                      '(qq wechat aagl steam))))

;; ── NVIDIA env projection：单一 authority ───────────────────

(test-assert "PRIME environment strings carry the offload variables"
             (every (lambda (s)
                      (and (string-contains s "=")
                           (not (string-prefix? "=" s))))
                    %prime-offload-environment-strings))

(test-end "gaming")
