;;; sudo 机器策略（host-agnostic）：/etc/sudoers 的 Defaults 声明。
;;; 内容静态 → 独立文件 colocate（同目录 sudoers，local-file）。
;;;
;;; 规则部分 = guix 默认 %sudoers-specification（root ALL=(ALL) ALL
;;; + %wheel ALL=(ALL) ALL，gnu/system.scm:1300）——测试对照默认
;;; 内容断言；不从 foreign record 取 content（跨编译单元的 record
;;; 类型身份陷阱，2026-09 实测）。
;;;
;;; Defaults 声明（2026-09）：
;;;   - lecture = never：无状态根下 /var/db/sudo/lectured 每次 boot
;;;     重建（不持久化），默认 lecture 会在每 boot 后首次 sudo 弹
;;;     提示——显式关闭（声明式消噪音）。
;;;   - passprompt = "[sudo] %p 的密码："：%p = 被请求密码的用户名
;;;     （sudoers man passprompt 的 % 转义表），与 Arch 的
;;;     "[sudo] password for %p:" 同风格。注意：自定义 passprompt
;;;     字符串【不】经 gettext（只有 sudo 编译期内置的默认提示可
;;;     翻译）——仓库 locale 固定 zh_CN.utf8（%common-locale），
;;;     硬编码中文与系统语言一致；想回到可翻译提示则删除本行
;;;     （默认 "Password: " → zh_CN 显示"密码："）。
;;;     语法由 guix validated-sudoers-file 在 OS 构建期经
;;;     `visudo --check` 强制校验，非法配置会在 reconfigure 时
;;;     fail-loud。

(define-module (guixcfg system sudo policy)
               #:use-module (guix gexp) ; local-file
               #:export (%sudoers-file))

(define %sudoers-file
  (local-file "sudoers" "sudoers"))
