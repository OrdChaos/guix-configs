;;; Noctalia seed-once 接入测试：seed 内容契约、persistence rule
;;; 声明（整目录 bind + settings.toml seed）、无第二配置源
;;; （不声明 ~/.config/noctalia 配置；niri 的 noctalia.kdl 是
;;; Noctalia 运行时生成，与 seed 模型无关）。

(use-modules (gnu services)          ; service-kind、service-value、service-type-name
             (guix records)
             (noctalia)              ; noctalia-git
             (guixcfg apps model)
             (guixcfg apps registry)
             (guixcfg apps noctalia-git definition)
             (guixcfg system application-persistence)
             (ice-9 rdelim)      ; read-string
             (srfi srfi-1)       ; count、any
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "noctalia-seed")

(define (read-file p)
  (call-with-input-file p (lambda (port) (read-string port))))

(define %seed-text
  (read-file "modules/guixcfg/apps/noctalia-git/base-settings.toml"))

;; ── 1. seed 内容契约（pinned Noctalia schema 键名）─────────
(test-assert "seed disables setup wizard"
             (string-contains %seed-text "setup_wizard_enabled = false"))
(test-assert "seed carries config_version (no first-run migration churn)"
             (string-contains %seed-text "config_version ="))
(test-assert "seed does not fake .setup-complete (no assignment; comment mention is documentation)"
             (not (string-contains %seed-text "setup-complete =")))
(test-assert "seed covers shell.screenshot directory"
             (string-contains %seed-text
                              "directory = \"~/Pictures/Screenshots\""))
(test-assert "seed covers launcher"
             (string-contains %seed-text "[shell.launcher]"))
(test-assert "seed covers theme"
             (string-contains %seed-text "mode = \"light\""))
(test-assert "seed covers wallpaper"
             (string-contains %seed-text "[wallpaper]"))
(test-assert "seed covers bar with tray/network/volume/battery widgets"
             (and (string-contains %seed-text "\"tray\"")
                  (string-contains %seed-text "\"network\"")
                  (string-contains %seed-text "\"volume\"")
                  (string-contains %seed-text "\"battery\"")))
(test-assert "seed covers osd"
             (string-contains %seed-text "[osd]"))
(test-assert "seed covers location"
             (string-contains %seed-text "[location]"))
(test-assert "seed covers lockscreen"
             (string-contains %seed-text "[lockscreen]"))
;; seed 是可移植初始状态（seed-once 语义）：禁止用户绝对路径
;; （/home/<user>——AGENT.md §13）与机器专属输出（eDP-1 等）。
(test-assert "seed is portable (no absolute /home paths)"
             (not (string-contains %seed-text "/home/")))
(test-assert "seed has no machine-specific monitor sections"
             (not (string-contains %seed-text "eDP-")))

;; ── 2. persistence rule 声明 ────────────────────────────────
(define rules (applications-persistence (list %noctalia-git)))
(test-equal "noctalia declares exactly one persistence rule"
            1 (length rules))
(define rule (car rules))
(test-equal "consumer is the whole state dir (no file whitelist)"
            ".local/state/noctalia"
            (application-persistence-rule-consumer rule))
(test-equal "backing is relative under /persist/data-app"
            "noctalia/state"
            (application-persistence-rule-backing rule))
(test-equal "exposure is directory bind"
            'bind-directory
            (application-persistence-rule-exposure rule))
(test-equal "lifecycle is application-owned"
            'application-owned
            (application-persistence-rule-lifecycle rule))
(test-assert "rule seeds settings.toml"
             (member "settings.toml"
                     (map car (application-persistence-rule-seeds rule))))
(test-equal "seed targets stay minimal (one entry)"
            '("settings.toml")
            (map car (application-persistence-rule-seeds rule)))
(test-assert "seeded rule passes validation"
             (valid-application-persistence-rule? rule))

;; ── 3. 无第二配置源：不声明 settings；palettes 是静态素材例外 ─
(define %noctalia-xdg-value
  (service-value
   (find (lambda (s)
           (eq? 'noctalia-palettes
                (service-type-name (service-kind s))))
         (application-home-services %noctalia-git))))

(test-assert "palettes are declared via home-xdg-configuration-files"
             (pair? %noctalia-xdg-value))
(test-assert "fluent-blue palette installed under noctalia/palettes"
             (assoc "noctalia/palettes/fluent-blue.json" %noctalia-xdg-value))
(test-assert "no declarative settings config (no second config source)"
             (not (assoc "noctalia/config.toml" %noctalia-xdg-value)))
(test-assert "no other .config/noctalia toml files declared"
             (not (any (lambda (target)
                         (string-suffix? ".toml" target))
                       (map car %noctalia-xdg-value))))
(test-assert "registry enables noctalia exactly once"
             (= 1 (count (lambda (a)
                           (eq? (application-name a) 'noctalia-git))
                         %applications)))

;; ── 4. fluent-blue.json 是合法 custom palette 形状 ──────────
(define %palette-text
  (read-file "modules/guixcfg/apps/noctalia-git/fluent-blue.json"))
(test-assert "palette has dark and light modes"
             (and (string-contains %palette-text "\"dark\"")
                  (string-contains %palette-text "\"light\"")))
(test-assert "palette carries Material tokens (mPrimary etc.)"
             (string-contains %palette-text "\"mPrimary\""))

(test-end "noctalia-seed")
