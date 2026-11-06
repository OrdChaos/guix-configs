;;; @deepseek-harness-tui/dsh-tui — 终端前端 bundle。
;;;
;;; 外部 npm bundle：版本和 tarball hash 手工 pin。上游把偏好目录固定在
;;; ~/.dsh-tui；在包构建阶段把它 patch 到 XDG 数据目录，使 profile 消费的
;;; 是已经修补过的插件，而不是把 patch 文件带进 profile。

(define-module (guixcfg apps dsh extensions tui)
  #:use-module (guix gexp) ;#~
  #:use-module (guix packages) ;base32
  #:use-module (guix utils) ;substitute-keyword-arguments
  #:use-module (virelith packages dsh-bundles)
  #:export (dsh-extension-tui))

(define-public dsh-extension-tui
  (let ((base (dsh-npm-bundle "@deepseek-harness-tui/dsh-tui" "0.19.0"
                              (base32
                               "19rdnb5fwf6r4l37q5sanfvpq8pgx9zn7mg4ij38zilzqqj1p955"))))
    (package
      (inherit base)
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:phases phases)
          #~(modify-phases #$phases
              (add-after 'validate-bundle 'patch-data-dir
                (lambda* (#:key outputs #:allow-other-keys)
                  (let ((root (string-append (assoc-ref outputs "out")
                               "/share/dsh/bundles/@deepseek-harness-tui/dsh-tui")))
                    (substitute* (string-append root
                                                "/lib/types/utils/paths.js")
                      (("export const DATA_DIR = join\\(homeDir\\(\\), '\\.dsh-tui'\\);")
                       (string-append
                        "const dataHome = process.env.XDG_DATA_HOME ?? "
                        "join(homeDir(), '.local/share');\n"
                        "export const DATA_DIR = process.env.DSH_TUI_DATA_DIR ?? "
                        "join(dataHome, 'dsh-tui');")))
                    (substitute* (string-append root "/bin/dsh-tui.js")
                      (("\\.dsh-tui")
                       ".local/share/dsh-tui"))))))))))))
