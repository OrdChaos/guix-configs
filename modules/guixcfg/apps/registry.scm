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
               #:use-module (guixcfg apps git definition)
               #:use-module (guixcfg apps dbus definition)
               #:use-module (guixcfg apps niri definition)
               #:use-module (guixcfg apps pipewire definition)
               #:use-module (guixcfg apps foot definition)
               #:use-module (guixcfg apps fuzzel definition)
               #:use-module (guixcfg apps mako definition)
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
               #:use-module (guixcfg apps gnome-keyring definition)
               #:use-module (guixcfg apps mpv definition)
               #:use-module (guixcfg apps google-chrome-stable definition)
               #:export (%applications))

(define %applications
  ;; 桌面/会话生命周期（官方 Home services 贡献其 profile 包，
  ;; 不要重复声明 package）。
  (list %bash %git %dbus %niri %pipewire
        ;; graphical user namespace（niri config spawn 的 consumer）
        %foot %fuzzel %mako %wl-clipboard %polkit-gnome
        ;; 独立选择的 CLI tools
        %ripgrep %fd %tree %jq %curl %wget %zip %less %file
        ;; 第一个真实 application-persistence production consumer
        %mpv
        ;; browser：官方 Chrome stable（nonguix）+ 整体 User Data
        ;; 持久化；cache 无状态；复用既有 Secret Service
        %google-chrome-stable
        ;; Secret Service / login keyring（official gnome-keyring
        ;; service + keyrings vault persistence）
        %gnome-keyring))

;; 完整性检查：启用集合的名字必须唯一（fail fast，加载即报错）。
(define %application-names (map application-name %applications))
(unless (= (length %application-names)
           (length (delete-duplicates %application-names)))
        (error "duplicate application name in registry" %application-names))
