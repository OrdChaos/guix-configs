;;; secrets 操作的运行环境（tools/secrets.scm 的工具链）：
;;;   age        加解密
;;;   util-linux script（age 的 passphrase 只从 /dev/tty 读——伪终端）
;;;   coreutils  stty（read-secret-line 的 noecho 密码读取）
;;; 用法：
;;;   guix time-machine -C channels.lock.scm -- shell -m manifests/secrets.scm -- \
;;;     guile -L modules -s tools/secrets.scm <init|unlock|...>
(specifications->manifest '("age" "util-linux" "coreutils"))
