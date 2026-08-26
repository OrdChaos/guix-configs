;;; VS Code 声明式扩展测试：固定插件集合、构建期 vsix 解包、
;;; activation 幂等部署服务、persistence 边界不变。
;;;
;;; 覆盖：
;;;   V1  声明集合恰好 2 个（zh-hans 语言包 + nord-light 主题）
;;;   V2  解包目录是 computed-file（构建期生成，非静态文件）
;;;   V3  解包后每个插件目录含 package.json（构建验证）
;;;   V4  activation 部署服务存在于 %vscode home-services
;;;   V5  persistence 仍是原有 4 条（扩展部署不新增规则）

(use-modules (guixcfg apps vscode definition)
             (guixcfg apps model)
             (guix download)          ; url-fetch
             (guix gexp)                ; computed-file?
             (guix records)
             (guix store)               ; open-connection
             (guix monads)
             (guix derivations)
             (guix hash)
             (guix packages)         ; origin?、origin-method、origin-hash
             (gnu services)             ; service-kind、service-type-name、service-value
             (gnu home services)        ; home-activation-service-type
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "vscode-extensions")

;; ── V1：声明集合 ────────────────────────────────────────────
(test-equal "V1: exactly two declared extensions"
            2 (length %vscode-declared-extensions))

(test-assert "V1: zh-hans language pack declared"
             (any (lambda (s)
                    (string=? "MS-CEINTL.vscode-language-pack-zh-hans-1.131.0"
                              (car s)))
                  %vscode-declared-extensions))

(test-assert "V1: nord-light theme declared"
             (any (lambda (s)
                    (string=? "huytd.nord-light-0.1.1" (car s)))
                  %vscode-declared-extensions))

(test-assert "V1: every vsix origin is url-fetch with a fixed sha256 hash"
             (every (lambda (o)
                      (let ((h (origin-hash o)))
                        (and (origin? o)
                             (eq? (origin-method o) url-fetch)
                             h
                             (eq? (content-hash-algorithm h) 'sha256))))
                    %vscode-extension-vsixs))

;; ── V2：构建期生成 ──────────────────────────────────────────
(test-assert "V2: extensions directory is a computed-file"
             (computed-file? (vscode-extensions-directory)))

;; ── V3：解包内容（真实构建）────────────────────────────────
(define %extensions-out
  (let* ((store (open-connection))
         (drv (run-with-store store
                              (lower-object (vscode-extensions-directory)))))
    (build-derivations store (list drv))
    (derivation->output-path drv)))

(test-assert "V3: each declared extension unpacks with package.json"
             (every (lambda (name)
                      (file-exists?
                       (string-append %extensions-out "/" name
                                      "/package.json")))
                    (map car %vscode-declared-extensions)))

(test-assert "V3: unpacked extension is a directory (not a vsix file)"
             (every (lambda (name)
                      (file-is-directory?
                       (string-append %extensions-out "/" name)))
                    (map car %vscode-declared-extensions)))

;; ── V4：activation 部署服务 ─────────────────────────────────
(test-assert "V4: vscode-extensions-deploy activation service present"
             (any (lambda (s)
                    (eq? 'vscode-extensions-deploy
                         (service-type-name (service-kind s))))
                  (application-home-services %vscode)))

;; ── V5：persistence 边界不变 ───────────────────────────────
(test-equal "V5: persistence rules unchanged (4 rules)"
            4 (length (application-persistence %vscode)))

(test-end "vscode-extensions")
