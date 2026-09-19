;;; Gaming 接线静态契约测试（2026-09 Steam 全线 Flatpak 化）：
;;;   - (guixcfg system gaming)：游戏库路径 authority
;;;     （persist-mount-point 派生 /persist/data-nobackup/steam）、
;;;     system services（steam-devices udev rules + 目录
;;;     activation）；
;;;   - Flatpak steam definition：id / managed overrides
;;;     （filesystem = 游戏库路径 authority 引用；environment =
;;;     %prime-offload-environment-strings 投影——不复制变量
;;;     字面量）；
;;;   - Flatpak aagl definition：NVIDIA PRIME managed overrides；
;;;   - registry：steam/aagl 在 catalog、extension catalog
;;;     （gamescope/proton-ge）与缺省 selection（公共子集）；
;;;   - per-host selection：lenovo 含 steam/aagl/extensions，
;;;     VM 保持缺省。

(use-modules (gnu services)          ; service-kind
             (gnu services base)     ; udev-service-type、activation-service-type
             (srfi srfi-1)           ; find
             (srfi srfi-13)          ; string-prefix?
             (srfi srfi-64)
             (guixcfg flatpak model)
             (guixcfg flatpak registry)
             (guixcfg flatpak applications steam)
             (guixcfg flatpak applications aagl)
             (guixcfg flatpak extensions gamescope)
             (guixcfg flatpak extensions proton-ge)
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

(test-equal "steam override projects the PRIME offload environment"
             %prime-offload-environment-strings
             (flatpak-override-environment %steam-overrides))

(test-assert "steam PRIME variables render in Flatpak Environment section"
             (let ((text (flatpak-render-override-file %steam-overrides)))
               (and (string-contains text "[Environment]")
                    (not (string-contains text "environment=")))))

;; ── flatpak aagl definition ─────────────────────────────────

(test-equal "aagl override projects the PRIME offload environment"
            %prime-offload-environment-strings
            (flatpak-override-environment
             (flatpak-application-managed-overrides %flatpak-aagl)))

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

(test-assert "default application selection is the common subset"
             (not (any (lambda (name)
                         (memq name %flatpak-selection))
                       '(steam aagl))))

(test-equal "default extension selection is empty"
            '() %flatpak-extension-selection)

;; ── per-host selection ──────────────────────────────────────

(test-assert "lenovo flatpak selection includes steam and aagl"
             (every (lambda (name)
                      (memq name
                            %lenovo-legion-y7000p-flatpak-selection))
                    '(steam aagl qq wechat)))

(test-assert "lenovo extension selection includes gamescope and proton-ge"
             (every (lambda (name)
                      (memq name
                            %lenovo-legion-y7000p-flatpak-extension-selection))
                     '(gamescope proton-ge)))

(test-assert "lenovo activation rules cover Steam and AAGL bind sources"
             (let ((consumers
                    (map application-persistence-rule-consumer
                         (host-application-persistence-rules
                          #:flatpak-selection
                          %lenovo-legion-y7000p-flatpak-selection))))
               (every (lambda (consumer) (member consumer consumers))
                      '(".var/app/com.valvesoftware.Steam"
                        ".var/app/moe.launcher.an-anime-game-launcher"))))

(test-assert "VM keeps the default flatpak selection"
             (equal? %flatpak-selection %vm-flatpak-selection))

(test-equal "VM selects no extensions"
            '() %vm-flatpak-extension-selection)

;; ── NVIDIA env projection：单一 authority ───────────────────

(test-assert "PRIME environment strings carry the offload variables"
             (every (lambda (s)
                      (and (string-contains s "=")
                           (not (string-prefix? "=" s))))
                    %prime-offload-environment-strings))

(test-end "gaming")
