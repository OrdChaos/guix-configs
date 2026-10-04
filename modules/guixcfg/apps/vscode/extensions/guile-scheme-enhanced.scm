;;; tsyesika.guile-scheme-enhanced —— Guile/Scheme 语法增强。
;;;
;;; 上游 activate() 每次启动都无条件执行
;;;   schemeConfig.update('autoIndent', 'none', ConfigurationTarget.Global)
;;; （src/main.js——注释自称 languageId 作用域，实际写全局，上游 bug），
;;; 对 repo-owned 只读 settings.json 反复写入失败。打包时抠掉这行：
;;; settings 的权威是本仓库，扩展不得触碰。

(define-module (guixcfg apps vscode extensions guile-scheme-enhanced)
  #:use-module (guix gexp) ;#~ #$
  #:use-module (guix packages) ;base32
  #:use-module (guix utils) ;substitute-keyword-arguments
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-guile-scheme-enhanced))

(define-public vscode-extension-guile-scheme-enhanced
  (let ((base (vscode-marketplace-extension "tsyesika"
                                            "guile-scheme-enhanced"
                                            "0.0.2"
                                            (base32
                                             "0hwk13j6n7rlyx94906bvqs2b0kw1ws81khy63kx206yn9yxi0ds")
                                            #:license license:asl2.0)))
    (package
      (inherit base)
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:phases phases)
          #~(modify-phases #$phases
              (add-after 'unpack 'drop-startup-settings-write
                (lambda _
                  ;; 已在 unpack 阶段 chdir 进 extension/。
                  (substitute* "src/main.js"
                    (("^.*schemeConfig\\.update\\('autoIndent'.*$")
                     "")))))))))))
