;;; Session gate：login gate 可变运行时资源的【唯一 authority】
;;; （docs/architecture/accounts-sessions.md、docs/development/
;;; invariants.md）。
;;;
;;; 一个可变运行时资源 = 一个权威定义 = 一个权威操作契约。gate 文件
;;; /run/guixcfg/session-not-ready 的 path / close / open 只在本模块
;;; 定义一次：
;;;
;;;   关闭端（boot）        ：(guixcfg system readiness) 经
;;;                          session-gate-close-activation（gexp builder）
;;;   打开端（readiness）   ：interactive-session-ready 的 start thunk
;;;   关闭/打开端（live）   ：(guixcfg system reconfigure) 的
;;;                          session-gate-close!/session-gate-open!
;;;   PAM 消费端            ：login-gate-pam-service 引用
;;;                          (session-gate-path ...)
;;;
;;; 三条路径使用同一 contract；不再存在第二份路径拼接 / mkdir /
;;; 写消息 / 删除实现。
;;;
;;; generated gexp 约束：session-gate-close-activation 只闭包
;;; (guix build utils)（channel 内模块，daemon 侧 lowering 可解析），
;;; gate 路径/目录/文案经 ungexp 字符串注入——不依赖外层模块 import
;;; 的偶然可见性。
;;;
;;; 关闭文案按语境区分（boot 与 live reconfigure 的 PAM 提示语不同），
;;; 但两者都定义在本模块（message 是 authority 的一部分）。
;;;
;;; 不建立后台 daemon / watcher / 轮询：gate 只是文件的存在性语义。

(define-module (guixcfg system session-gate)
               #:use-module (guix gexp)          ; with-imported-modules、program-file 用到的 gexp 机制
               #:use-module (guix modules)       ; source-module-closure
               #:use-module (guix build utils)   ; mkdir-p（runtime 过程的 close! 用）
               #:export (%session-gate-directory
                         %session-gate-file-name
                         %session-gate-path
                         %session-gate-close-message
                         %session-gate-reconfigure-message
                         session-gate-path
                         session-gate-close!
                         session-gate-open!
                         session-gate-close-activation))

;;; ── path facts（唯一定义处）───────────────────────────────

(define %session-gate-directory "/run/guixcfg")
(define %session-gate-file-name "session-not-ready")
(define %session-gate-path
  (string-append %session-gate-directory "/" %session-gate-file-name))

;;; ── message facts（唯一定义处；PAM 提示语按语境区分）───────

(define %session-gate-close-message
  "The system is not ready for interactive logins yet.\n")

(define %session-gate-reconfigure-message
  "A reconfigure is in progress.\n")

;;; ── 操作契约（runtime 过程；测试经 #:directory 注入）───────

(define* (session-gate-path #:key (directory %session-gate-directory))
  "DIRECTORY 下的 gate 文件路径。"
  (string-append directory "/" %session-gate-file-name))

(define* (session-gate-close! #:key
                              (directory %session-gate-directory)
                              (message %session-gate-close-message))
  "关闭 gate（创建 gate 文件）。幂等：目录 mkdir-p + chmod 0755
  （/run/guixcfg 是本项目的 privileged 运行时命名空间），写入
  MESSAGE。"
  (mkdir-p directory)
  (chmod directory #o755)
  (call-with-output-file (session-gate-path #:directory directory)
    (lambda (port)
      (display message port))))

(define* (session-gate-open! #:key (directory %session-gate-directory))
  "打开 gate（删除 gate 文件）。幂等：文件不存在时无操作。"
  (false-if-exception
   (delete-file (session-gate-path #:directory directory))))

;;; ── boot 关闭端（activation gexp builder）──────────────────
;;; 只闭包 (guix build utils)；路径/目录/文案全部 ungexp 字符串。

(define* (session-gate-close-activation
          #:key (directory %session-gate-directory)
                (message %session-gate-close-message))
  "activation gexp：boot 早期关闭 gate（mkdir-p + chmod + 写文案）。
DIRECTORY/MESSAGE 经 ungexp 注入（测试可用临时目录）。"
  (with-imported-modules (source-module-closure '((guix build utils)))
                         #~(begin
                            (use-modules (guix build utils))
                            (mkdir-p #$directory)
                            (chmod #$directory #o755)
                            (call-with-output-file #$(session-gate-path
                                                      #:directory directory)
                                                   (lambda (port)
                                                     (display #$message
                                                              port))))))
