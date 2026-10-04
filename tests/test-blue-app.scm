;;; Blue application 测试：%blue 是 <application>、package 来自
;;; pinned bluebox、registry 恰好启用一次、aggregation 后进入 Home
;;; package set。
;;; 由 tests/run-tests.scm 加载运行（从仓库根目录）。

(use-modules (guixcfg apps registry) ;%applications（启用事实源）
             (guixcfg apps blue definition)
             (srfi srfi-1)
             (srfi srfi-64))

(test-runner-current (test-runner-simple))

(test-begin "blue-app")

(test-assert "registry enables blue exactly once"
             (= 1
                (count (lambda (a)
                         (eq? a %blue)) %applications)))

(test-end)
