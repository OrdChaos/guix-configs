;;; Application registry：显式启用列表。目录存在 != 应用启用——
;;; 启用/禁用应用只能改这里。不自动扫描 apps/*/definition.scm。
;;;
;;; Host/Home assembly 经 (guixcfg apps model) 的 aggregation
;;; functions 消费 %applications：
;;;   applications-home-packages / applications-home-services /
;;;   applications-system-services / applications-persistence /
;;;   applications-secrets

(define-module (guixcfg apps registry)
               #:use-module (srfi srfi-1)             ; delete-duplicates
               #:use-module (guixcfg apps model)
               #:use-module (guixcfg apps bash definition)
               #:use-module (guixcfg apps fastfetch definition)
               #:use-module (guixcfg apps git definition)
               #:use-module (guixcfg apps dbus definition)
               #:use-module (guixcfg apps niri definition)
               #:use-module (guixcfg apps noctalia definition)
               #:use-module (guixcfg apps pipewire definition)
               #:use-module (guixcfg apps ghostty definition)
               #:use-module (guixcfg apps nautilus definition)
               #:use-module (guixcfg apps wl-clipboard definition)
               #:use-module (guixcfg apps polkit-gnome definition)
               #:use-module (guixcfg apps ripgrep definition)
               #:use-module (guixcfg apps fd definition)
               #:use-module (guixcfg apps tree definition)
               #:use-module (guixcfg apps jq definition)
               #:use-module (guixcfg apps curl definition)
               #:use-module (guixcfg apps wget definition)
               #:use-module (guixcfg apps zip definition)
               #:use-module (guixcfg apps less definition)
               #:use-module (guixcfg apps file definition)
               #:use-module (guixcfg apps mesa-utils definition)
               #:use-module (guixcfg apps gnome-keyring definition)
               #:use-module (guixcfg apps mpv definition)
               #:use-module (guixcfg apps google-chrome-stable definition)
               #:use-module (guixcfg apps gnupg definition)
               #:use-module (guixcfg apps seahorse definition)
               #:use-module (guixcfg apps ssh definition)
               #:use-module (guixcfg apps fcitx5 definition)
               #:use-module (guixcfg apps gtk definition)
               #:use-module (guixcfg apps xsettingsd definition)
               #:use-module (guixcfg apps amberol definition)
               #:use-module (guixcfg apps celluloid definition)
               #:use-module (guixcfg apps loupe definition)
               #:use-module (guixcfg apps gnome-text-editor definition)
               #:use-module (guixcfg apps gnome-characters definition)
               #:use-module (guixcfg apps vscode definition)
               #:use-module (guixcfg apps onlyoffice definition)
               #:use-module (guixcfg apps nushell definition)
               #:use-module (guixcfg apps starship definition)
               #:use-module (guixcfg apps blue definition)
               #:export (%applications))

(define %applications
  ;; 桌面/会话生命周期（官方 Home services 贡献其 profile 包，
  ;; 不要重复声明 package）。
  (list %bash
        %git
        %dbus
        %niri
        %noctalia
        %pipewire
        %ghostty
        %nautilus
        %wl-clipboard
        %polkit-gnome
        %ripgrep
        %fd
        %tree
        %jq
        %curl
        %wget
        %zip
        %less
        %file
        %mesa-utils
        %fastfetch
        %mpv
        %google-chrome-stable
        %gnome-keyring
        %gnupg
        %seahorse
        %ssh
        %fcitx5
        %gtk
        %xsettingsd
        %amberol
        %celluloid
        %loupe
        %gnome-text-editor
        %gnome-characters
        %vscode
        %onlyoffice
        %nushell
        %starship
        %blue))

;; 完整性检查：启用集合的名字必须唯一（fail fast，加载即报错）。
(define %application-names (map application-name %applications))
(unless (= (length %application-names)
           (length (delete-duplicates %application-names)))
  (error "duplicate application name in registry" %application-names))
