;;; Tailscale 部署策略（host-independent 的单一 authority）。
;;;
;;; login-server 是同一 tailnet 内所有 profile 共享的结构事实；具体
;;; 主机只决定是否启用 Tailscale，不重复拼写控制面 URL。
;;; mihomo template 的 DIRECT 域名规则必须与此保持一致
;;; （modules/guixcfg/system/mihomo/template.yaml）。

(define-module (guixcfg system tailscale config)
  #:export (%tailscale-login-server))

(define %tailscale-login-server
  "https://edge.ordchaos.eu.org:9443")
