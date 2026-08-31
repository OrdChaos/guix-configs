;;; 统一字体集合与 Fontconfig generic-family/fallback 策略的 Home
;;; 集成（Guix Home owns）。
;;;
;;; 职责划分：
;;;   - %fonts 与 fontconfig 策略（SXML 数据）：中立事实层
;;;     (guixcfg fonts model) / (guixcfg fonts fontconfig-policy) 拥有
;;;     （System profile 的 Flatpak 字体投影与
;;;     ONLYOFFICE 兼容层等消费同一份；本模块不再持有定义）；
;;;   - 本模块只剩 Home 机制：home-fontconfig-service-type 服务包装
;;;     （snippet → $XDG_CONFIG_HOME/fontconfig/fonts.conf）与 XDG
;;;     字体链接农场。
;;;   应用层（GTK/Qt/browser/editor）配置不在本模块范围。
;;; 生成机制：官方 home-fontconfig-service-type（pinned guix 8a2afa6
;;; (gnu home services fontutils)）——value 是 snippet 列表：字符串
;;; → <dir>，list → 原样 SXML，输出
;;; $XDG_CONFIG_HOME/fontconfig/fonts.conf，activation 时 fc-cache。
;;; 不手写 XML 模板、无 shell 生成、无 activation hook。
;;;
;;; 注意（pinned guix 8a2afa6 审计）：home-environment 的
;;; home-environment-default-essential-services 已自带一个
;;; home-fontconfig 实例（default value '("~/.guix-home/profile/
;;; share/fonts")，即 profile 字体目录）。因此本模块用
;;; simple-service 扩展该 canonical 实例（只贡献 SXML 规则），
;;; 不创建第二个同型 service（否则 .config/fontconfig/fonts.conf
;;; 出现重复条目）。目录 snippet 由 essential 默认值提供。
;;;
;;; XDG 字体链接农场（~/.local/share/fonts/<pkg> → store
;;; share/fonts）：为环境被 CEF 白名单式清洗的渲染进程提供字体
;;; 目录。诊断链（2026-08 onlyoffice 字体缺失，全部实测）：
;;;   1. ONLYOFFICE 自身的 fontconfig 初始化会整目录加载所加载
;;;      fontconfig 包的 share/fontconfig/conf.avail；其中的
;;;      05-reset-dirs-sample.conf 含 <reset-dirs/>，把此前配置链
;;;      （store fonts.conf + conf.d + 用户配置）积累的全部字体目录
;;;      清空，只保留该 sample 重新声明的
;;;      <dir prefix="xdg">fonts</dir>（strace + 配置链模拟复现：
;;;      带该 pass 0 字体，不带 1589）。
;;;   2. CEF 的 zygote 对渲染进程环境做白名单式清洗（实测保留
;;;      HOME/LANG/PATH/DBUS_* 等；XDG_DATA_DIRS、FONTCONFIG_*、
;;;      LD_*、自定义变量全部剥除）——prefix="xdg" 的目录解析在
;;;      渲染进程里只剩 HOME fallback：~/.local/share/fonts（+
;;;      /usr/local/share、/usr/share 的 FHS 默认，Guix 无）。
;;;   3. 因此只有 ~/.local/share/fonts 下的字体能被渲染进程看到
;;;      （文档渲染 tofu、字体列表只剩 bundled 字体的直接原因）。
;;;      字体规则（alias/lang edit）不受 reset 影响——reset 只清
;;;      目录，本模块的 generic family 策略在渲染进程中依然生效
;;;      （fc-match sans-serif:lang=zh-cn → MiSans 实测）。
;;;
;;; 本服务为每个携带 share/fonts 的字体包在 ~/.local/share/fonts/
;;; 下建立指向 store 目录的链接（fontconfig 扫描时跟随子目录
;;; symlink——truetype/opentype 子目录链接实测生效；per-package
;;; 两层链接同构）。语义与 Home 其余资源一致：纯 store symlink、
;;; 随 Home generation 重建、不进 persistence、无 activation 复制。
;;;
;;; 已知权衡：同一字体文件经两条路径可见（profile share 经
;;; XDG_DATA_DIRS + 本农场），fc-list 文件级列表出现双份条目；
;;; 按 family 聚合的选择器（GTK/Chromium/ONLYOFFICE）天然去重，
;;; 匹配语义不受影响。removal condition：上游不再整目录加载
;;; conf.avail / 停止 reset-dirs / CEF 停止清洗渲染进程环境。

(define-module (guixcfg home fonts)
               #:use-module (gnu home services fontutils) ; home-fontconfig-service-type
               #:use-module (gnu home services) ; home-files-service-type
               #:use-module (gnu services)      ; service、simple-service
               #:use-module (guix gexp)         ; file-append
               #:use-module (guix packages)     ; package-name
               #:use-module (gnu packages fontutils) ; fontconfig（工具包，农场结构性跳过）
               #:use-module (guixcfg fonts model)  ; %fonts（re-export）
               #:use-module (guixcfg fonts fontconfig-policy) ; %fontconfig-snippets
               #:use-module (srfi srfi-1)       ; append-map、delete
               #:export (%fontconfig-service
                         %home-fonts-xdg-link-service)
               #:re-export (%fonts))

;; ── 字体集合（shared fact）─────────────────────────────────
;; %fonts 由 (guixcfg fonts model) 提供并在此 re-export（single
;; source；System 的 Flatpak 字体投影也消费同一份——
;; docs/architecture/flatpak.md（fonts））。

;; ── Fontconfig snippet 构造 ─────────────────────────────────
;; 策略数据（family 链、alias/lang edit 构造器、%fontconfig-snippets）
;; 已全部上提到中立事实层 (guixcfg fonts fontconfig-policy)——本
;; 模块只消费。目录不进 snippets（由 essential 默认值提供）。


;; 经 native extension 贡献到 canonical home-fontconfig 实例
;; （essential services 已实例化；AGENT.md §15 同款模式）。
(define %fontconfig-service
  (simple-service 'guixcfg-fontconfig
                  home-fontconfig-service-type
                  %fontconfig-snippets))

;; ── XDG 字体链接农场（头部诊断链）──────────────────────────
;; 每个携带 share/fonts 的字体包 → ~/.local/share/fonts/<pkg-name>
;; 的目录链接（fontconfig 跟随子目录 symlink）。fontconfig 是
;; 工具包（无 share/fonts），结构性跳过。
(define %home-fonts-xdg-link-service
  (simple-service 'home-fonts-xdg-links
                  home-files-service-type
                  (map (lambda (pkg)
                         (list (string-append ".local/share/fonts/"
                                              (package-name pkg))
                               (file-append pkg "/share/fonts")))
                       (delete fontconfig %fonts))))
