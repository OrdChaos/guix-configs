;;; Node.js application unit：Node.js 运行时（含 npm）+ pnpm。
;;;
;;; node 来自 pinned guix（gnu packages node，自带 npm）；pnpm 来自
;;; virelith（pnpm 不在 pinned guix——virelith packages nodejs，
;;; 2026-09 加入）。
;;;
;;; pmOnFail=ignore（Guix 是 pnpm 版本的唯一 authority）：
;;;   项目 package.json 声明 packageManager / devEngines.
;;;   packageManager 与本机 pnpm 不一致时，pnpm 11 默认
;;;   onFail=download——联网拉取声明版本并切换执行。本仓库的 pnpm
;;;   是 store 内不可变包（版本由 channels.lock.scm 决定，2026-09
;;;   为 11.21.0）：项目声明的版本既不是本机版本 authority，其下载
;;;   产物也落在 store 之外（不可复现）。因此显式 ignore：跳过版本
;;;   检查，直接用 store 的 pnpm 执行。
;;;
;;; 只能经环境变量设置（pinned pnpm 11.21.0 实测，2026-09）：
;;;   - 配置文件不可行：pnpm 11 的非 auth/registry 设置不读 .npmrc，
;;;     全局 ~/.config/pnpm/config.yaml 只接受 config-file key 白名单
;;;     （pmOnFail 在 pnpm 内部 excludedPnpmKeys 内）——实测写入
;;;     global config.yaml 后告警 "cannot be set in the global config
;;;     file ... \"pmOnFail\"" 且仍执行版本切换；
;;;   - --pm-on-fail=ignore 需要包装脚本（第二 owner）；
;;;     项目级 pnpm-workspace.yaml 只覆盖单个项目——都不是全局语义；
;;;   - pnpm_config_pm_on_fail=ignore 是 pnpm 官方为 "版本由外部工具
;;;     管理（asdf/mise/Volta）" 提供的开关，Guix 正属此类；实测
;;;     版本不匹配时不再切换（--version 直接输出 11.21.0）。
;;;   变量经 Home 会话环境进入整个会话（home-environment-variables
;;;   共享 sink 的 native extension，apps/fcitx5 同款模式），pnpm
;;;   自身为子进程注入同名变量，互不冲突。

(define-module (guixcfg apps nodejs definition)
               #:use-module (gnu home services)        ; home-environment-variables-service-type
               #:use-module (gnu packages node)        ; node（含 npm）
               #:use-module (gnu services)             ; simple-service
               #:use-module (guix records)
               #:use-module (virelith packages nodejs) ; pnpm
               #:use-module (guixcfg apps model)
               #:export (%nodejs))

(define %nodejs
  (application
   (name 'nodejs)
   (home-packages (list node pnpm))
   (home-services
    (list (simple-service
           'nodejs-env
           home-environment-variables-service-type
           '(("pnpm_config_pm_on_fail" . "ignore")))))))
