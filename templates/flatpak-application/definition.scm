;;; Flatpak application definition 模板（docs/architecture/
;;; flatpak.md（application model））。
;;;
;;; 标准流程：
;;;   cp templates/flatpak-application/definition.scm \
;;;      modules/guixcfg/flatpak/applications/wechat.scm
;;;   1. 修改模块名 (guixcfg flatpak applications wechat)；
;;;   2. 修改 %FLATPAK-APP → %flatpak-wechat、'app → 'wechat、
;;;      id/branch 等字段（app-id/branch 以 Flathub 官方页面核实）；
;;;   3. 在 modules/guixcfg/flatpak/registry.scm：
;;;        import 本模块 + aggregation list 加 %flatpak-wechat；
;;;      %flatpak-selection 加 'wechat；
;;;   4. build/test/reconfigure（reconfigure 后 persistence/override
;;;      投影自动生效，无其它文件要改）。
;;;
;;; 规则（definition = 应用是什么；selection = 设备要哪些）：
;;;   - definition 自包含全部业务事实（identity/ref/update policy/
;;;     override policy/persistence intent），registry 只聚合；
;;;   - persistence 默认 ~/.var/app/<id> 由 application ID 推导
;;;     （service 投影显式实现）；只有默认之外的例外才写
;;;     extra-persistence（(consumer backing) 两元素列表，backing
;;;     相对 flatpak/apps/ 命名空间）；
;;;   - update-policy：'track-branch（默认）或
;;;     (flatpak-commit-pin "<hex>")（例外，必须注释理由）；
;;;   - override-policy：'external（user/Flatseal owns，先以上游
;;;     manifest 权限运行；实机验证需要的 delta 后按 Flatseal
;;;     工作流改为 (managed-overrides ...)，flatpak.md（overrides））；
;;;   - remote 用 registry 里的 logical name（'flathub），不写 URL；
;;;   - 默认应用/MIME 关联不在 definition："是否默认"是用户级策略，
;;;     统一 XDG 模块 (guixcfg home xdg) 消费本模块导出的
;;;     desktop-entry 常量（<id>.desktop，Flatpak exports 固定
;;;     命名）——policy → app metadata，本模块不反向依赖 xdg
;;;     （参考 applications/onlyoffice.scm）；
;;;   - 目录存在 != 应用启用：启用必须进 registry 与 selection。
;;;
;;; 生产参考：modules/guixcfg/flatpak/applications/qq.scm。

(define-module (guixcfg flatpak applications app)
               #:use-module (guixcfg flatpak model) ; flatpak-application
               #:export (%flatpak-app))

(define %flatpak-app
  (flatpak-application
   (name 'app)                       ; symbol：logical name（selection 的键；registry 里唯一）
   (id "org.example.App")            ; Flatpak app-id（≥2 个 '.' 段；Flathub 页面核实）
   (remote 'flathub)                 ; registry 声明的 remote logical name
   (branch "stable")                 ; Flatpak ref branch
   ;; (update-policy 'track-branch)  ; 默认；pin 例外：
   ;;                                 ; (update-policy (list 'flatpak-commit-pin
   ;;                                 ;                    "0123..."))
   ;; (override-policy 'external)    ; 默认；repo 管理时：
   ;;                                 ; (override-policy
   ;;                                 ;   (list 'managed-overrides
   ;;                                 ;         (flatpak-override
   ;;                                 ;           (sockets '("wayland"))
   ;;                                 ;           ...)))
   ;; (extra-persistence              ; 默认 ~/.var/app/<id> 之外的例外
   ;;  '((".local/share/wechat" "wechat/share")))  ; (consumer backing)
   ))
