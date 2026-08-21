;;; Google Chrome application unit：官方 Chrome stable 二进制 +
;;; Chromium User Data Directory 持久化边界（docs/architecture/
;;; persistence.md production consumers）。
;;;
;;; 来源（pinned nonguix 653504e6 审计）：google-chrome-stable
;;; 定义于 (nongnu packages chrome)（不是 chromium.scm 的
;;; chromium-embedded-framework）；v151.0.7922.75-1，
;;; chromium-binary-build-system（nonguix 官方 wrapper：/bin/
;;; google-chrome-stable + CHROME_WRAPPER + .desktop 安装），
;;; #:substitutable? #f（Google 服务器直下 deb，不经 substitutes）；
;;; supported-systems 仅 x86_64-linux。不复制定义、不自建 wrapper。
;;;
;;; 持久化边界（决策已定，不做 profile 内部细分）：
;;;   - 持久化：~/.config/google-chrome/ 整体（Chromium 官方 User
;;;     Data Directory；Cookies/History/Extensions/IndexedDB/Local
;;;     Storage/Service Worker/ShaderCache 等一律随目录走）；
;;;   - 不持久化：~/.cache/google-chrome/（ephemeral，重启重建）；
;;;   - 不新增 ~/.pki/nssdb 持久化（证书/NSS 状态归未来独立证书
;;;     基础设施，Chrome 不拥有）；程序文件在 store/profile，非
;;;     持久状态。
;;;
;;; Keyring（已实现，不改）：Chrome 经 D-Bus 自动使用现有
;;; org.freedesktop.secrets（既有 Secret Service 会话服务；login
;;; collection 会话启动即解锁，见 docs/architecture/
;;; desktop-authentication.md）。默认 password store 自动探测：
;;; Secret Service 可用即正常使用，不需要 basic 回退模式；Chrome
;;; 凭据落入既有 keyrings vault（gnome-keyring app 自己的
;;; persistence rule 持久化）——本模块不产生第二套 secret storage。
;;;
;;; 桌面集成（既有会话已满足，无新增）：.desktop 文件经 profile
;;; share/applications 进 XDG_DATA_DIRS（应用启动器自动发现）；Wayland
;;; 原生，X11 fallback 走 xwayland-satellite（会话已有）；字体由包
;;; 自带 + font-liberation input。默认参数运行，不加 Chromium flags。
;;;
;;; 职责边界（AGENT.md §Application layer）：本模块只描述“Chrome
;;; 是什么”——package、User Data 持久化、desktop entry 纯数据常量
;;; （%chrome-desktop-entry）。“Chrome 是否被选作默认浏览器”是
;;; 用户级策略，属于统一 XDG/default-apps 模块 (guixcfg home xdg)：
;;; 它消费 %chrome-desktop-entry 生成 $XDG_CONFIG_HOME/mimeapps.list
;;; （derived state，不持久化）。依赖方向 policy → app metadata，
;;; 本模块不反向依赖 xdg。

(define-module (guixcfg apps google-chrome-stable definition)
               #:use-module (nongnu packages chrome)   ; google-chrome-stable
               #:use-module (guix records)
               #:use-module (guixcfg apps model)       ; application
               #:use-module (guixcfg system application-persistence) ; rule
               #:export (%google-chrome-stable
                         %chrome-desktop-entry))

;; Chrome stable 的 XDG desktop entry（store 内实际构建产物
;; share/applications/ 核实；nonguix patch-assets 阶段会重写其 Exec
;; 指向 wrapper）。纯数据常量：供统一 XDG 策略模块引用，不在此决定
;; 默认应用。
(define %chrome-desktop-entry "google-chrome.desktop")

(define %google-chrome-stable
  (application
   (name 'google-chrome-stable)
   (home-packages (list google-chrome-stable))
   (persistence
    (list (application-persistence-rule
           (name 'user-data)
           (backing "google-chrome-stable/user-data") ; backing root 相对（persistence.md）
           (consumer ".config/google-chrome")         ; HOME 相对（官方 User Data）
           (exposure 'bind-directory)
           (lifecycle 'application-owned))))))
