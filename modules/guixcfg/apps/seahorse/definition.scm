;;; seahorse application unit：GNOME 密码与密钥 GUI（PGP / SSH key
;;; 与 GNOME Keyring 的统一管理器）。
;;;
;;; 集成边界：
;;;   - PGP 页签经 GPGME 读 GNUPGHOME——由 gnupg app 提供
;;;     （ephemeral /run/user/<uid>/gnupg，session 开始已 import）；
;;;     seahorse 依赖 gnupg app 启用（软依赖：缺省时 PGP 页签为空，
;;;     Passwords 页签仍可用）。无需独立配置。
;;;   - Passwords 页签走 Secret Service——由 gnome-keyring app 提供
;;;     （vault 持久化在 application persistence root 下的
;;;     gnome-keyring/keyrings）。
;;;   - SSH 页签读 ~/.ssh——由 ssh app 提供（见 apps/ssh）。
;;;
;;; ⚠️ 生命周期契约：seahorse 里**生成**的新 key 落在 ephemeral
;;; GNUPGHOME，session 结束即消失。想要持久 key 必须走仓库 age
;;; 流程（导出 armor → age 加密 → apps/gnupg/secrets/），不要用
;;; seahorse 生成。

(define-module (guixcfg apps seahorse definition)
               #:use-module (gnu packages gnome) ; seahorse
               #:use-module (guix records)
               #:use-module (guixcfg apps model)
               #:export (%seahorse))

(define %seahorse
  (application
   (name 'seahorse)
   (home-packages (list seahorse))))
