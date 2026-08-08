;;; 系统公共部分：所有 host 共享的基础设置。
;;; 对应 docs/system.md 第 21–22 章（host 是组装点，共享内容放这里）。

(define-module (guixcfg system common)
               #:export (%common-timezone
                         %common-locale))

;; 时区与区域设置：两台机器相同。
(define %common-timezone "Asia/Shanghai")

;; VM 阶段先用 en_US.utf8（locale 数据小、验证简单）；
;; 桌面阶段（阶段 7）再按需要加 zh_CN.utf8 等 locale 定义。
(define %common-locale "en_US.utf8")
