;;; Noctalia seed portability and single-configuration-source tests.

(use-modules (gnu services) ;service-kind、service-value、service-type-name
              (guixcfg apps model)
              (guixcfg apps noctalia definition)
              (ice-9 rdelim) ;read-string
              (srfi srfi-1) ;any
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "noctalia-seed")

(define (read-file p)
  (call-with-input-file p
    (lambda (port)
      (read-string port))))

(define %seed-text
  (read-file "modules/guixcfg/apps/noctalia/base-settings.toml"))

;; ── 1. seed 内容契约（pinned Noctalia schema 键名）─────────
;; seed 是可移植初始状态（seed-once 语义）：禁止用户绝对路径
;; （/home/<user>——AGENT.md §13）与机器专属输出（eDP-1 等）。
(test-assert "seed is portable (no absolute /home paths)"
             (not (string-contains %seed-text "/home/")))
(test-assert "seed has no machine-specific monitor sections"
             (not (string-contains %seed-text "eDP-")))

;; ── 2. No second configuration source ────────────────────────
(define %noctalia-xdg-value
  (service-value (find (lambda (s)
                         (eq? 'noctalia-palettes
                              (service-type-name (service-kind s))))
                       (application-home-services %noctalia))))

(test-assert "no declarative settings config (no second config source)"
             (not (assoc ".config/noctalia/config.toml" %noctalia-xdg-value)))
(test-assert "no other .config/noctalia toml files declared"
             (not (any (lambda (target)
                         (string-suffix? ".toml" target))
                       (map car %noctalia-xdg-value))))
(test-end "noctalia-seed")
