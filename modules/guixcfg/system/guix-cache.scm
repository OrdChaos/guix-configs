;;; Root 侧 Guix channel checkout 缓存的 machine-state persistence。
;;;
;;; 问题：blue reconfigure / converge 以 root 运行
;;; `guix time-machine -C channels.lock.scm`；guix 的 channel checkout
;;; 缓存位于 $HOME/.cache/guix/checkouts——root 侧即
;;; /root/.cache/guix/checkouts。本机是无状态根（每次换 root
;;; generation 即丢弃），因此每次 reconfigure 都要从零 clone 全部
;;; channel（codeberg 的 guix.git 全量历史在慢链路上需数小时，
;;; 2026-10-03 实测 ~150KB/s）。
;;;
;;; 修复：把 root 的 guix 缓存整体纳入 generic machine-state
;;; persistence——/persist/system/state/guix/root-cache →
;;; /root/.cache/guix。consumer 在无状态根上每次 boot 天然为空，
;;; 不涉及已有数据迁移（机制不变量 4 不适用）。
;;;
;;; 不合并 user 侧缓存（~/.cache/guix，持久 HOME）：两个缓存服务
;;; 不同 actor（user guix CLI vs root time-machine）。共享单一后端
;;; 会让 root 侧 fetch 在 user 缓存里写入 root-owned git 对象，反向
;;; 破坏 user 侧后续写入（ownership 冲突）；分离的代价比共享的
;;; 正确性风险低。磁盘成本 ≈ 两份 checkout，可接受。
;;;
;;; ownership 用机制默认（root:root）：缓存内容全是公开 channel 的
;;; git 对象，无 secret；不引入 owner/mode 抽象。

(define-module (guixcfg system guix-cache)
  #:use-module (guixcfg system machine-state-persistence)
  #:export (%guix-root-cache-persistence-rule))

;; /persist/system/state/guix/root-cache → /root/.cache/guix
;; （root-owned machine state；consumer 是 root 侧 guix 运行期
;; 读取的默认缓存位置）。
(define %guix-root-cache-persistence-rule
  (machine-state-persistence-rule (name 'guix-root-cache)
                                  (backing "guix/root-cache")
                                  (consumer "/root/.cache/guix")))
