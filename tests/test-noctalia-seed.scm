;;; Noctalia seed portability and single-configuration-source tests.
;;; base seed 必须可移植（无 /home、无显示器 connector）；仅 laptop
;;; 变体可以带内屏布局，host 经 logical seed selection 选用。

(use-modules (gnu services) ;service-kind、service-value、service-type-name
             (guixcfg apps model)
             (guixcfg apps noctalia definition)
             (guixcfg system application-persistence) ;rule accessors
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
             (and (not (string-contains %seed-text "eDP-"))
                  (not (string-contains %seed-text "Virtual-"))))

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
;; ── 3. host seed variants（host 只做 logical selection）─────
(define %laptop-seed-text
  (read-file "modules/guixcfg/apps/noctalia/variants/laptop-settings.toml"))
(define %vm-seed-text
  (read-file "modules/guixcfg/apps/noctalia/variants/vm-settings.toml"))

(test-assert "laptop seed carries the internal panel layout"
             (string-contains %laptop-seed-text "eDP-1"))
(test-assert "laptop seed stays free of user absolute paths"
             (not (string-contains %laptop-seed-text "/home/")))
(test-assert "vm seed carries the Virtual-1 layout"
             (string-contains %vm-seed-text "Virtual-1"))
(test-assert "vm seed stays free of user absolute paths"
             (not (string-contains %vm-seed-text "/home/")))

(define %state-rule
  (find (lambda (rule)
          (eq? 'state (application-persistence-rule-name rule)))
        (application-persistence %noctalia)))

(test-assert "noctalia declares the laptop seed variant"
             (assq 'laptop
                   (application-persistence-rule-seed-variants %state-rule)))
(test-assert "noctalia declares the vm seed variant"
             (assq 'vm
                   (application-persistence-rule-seed-variants %state-rule)))
(test-assert "selecting the laptop variant swaps the seed source"
             (not (equal? (application-persistence-rule-seeds
                           (application-persistence-rule-for-variant
                            %state-rule 'laptop))
                          (application-persistence-rule-seeds %state-rule))))
(test-assert "selecting the vm variant swaps the seed source"
             (not (equal? (application-persistence-rule-seeds
                           (application-persistence-rule-for-variant
                            %state-rule 'vm))
                          (application-persistence-rule-seeds %state-rule))))

(test-end "noctalia-seed")
