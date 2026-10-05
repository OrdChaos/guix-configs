;;; tsyesika.guile-scheme-enhanced —— Guile/Scheme 语法增强。
;;;
;;; 两处打包期修补：
;;;
;;; 1. 启动写 settings（上游 bug）：activate() 每次启动都无条件执行
;;;    schemeConfig.update('autoIndent', 'none', ConfigurationTarget.Global)
;;;    （注释自称 languageId 作用域，实际写全局），对 repo-owned 只读
;;;    settings.json 反复写入失败。抠掉这行：settings 的权威是本仓库，
;;;    扩展不得触碰。
;;;
;;; 2. language id 统一到 "scheme"：本扩展把 .scm 注册为自家 id
;;;    "guile"，而 rgherdt.scheme-lsp 注册为 "scheme"——VS Code 对
;;;    同扩展名的多个注册按"后注册者胜出"（languagesAssociations.ts
;;;    getAssociationByPath），结果取决于扩展加载顺序，用户不可控。
;;;    两个扩展能力互补（语法/缩进 vs LSP），统一到 scheme 后由 VS Code
;;;    的 _mergeLanguage 合并贡献，配合 settings.json 的
;;;    files.associations 双保险。改动面：package.json 的
;;;    languages[0].id 与 grammars[0].language；main.js 的三处
;;;    'guile'（languageId 判断、document selector、已死的
;;;    getConfiguration 作用域——settings 写入行已被修补 1 删除）。
;;;    升级本扩展版本时复查本 patch（上游文件结构可能变化）。

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
                      ""))))
               (add-after 'unpack 'unify-language-id
                 (lambda _
                   (substitute* "package.json"
                     (("\"id\": \"guile\"") "\"id\": \"scheme\"")
                     (("\"language\": \"guile\"") "\"language\": \"scheme\""))
                   (substitute* "src/main.js"
                     (("'guile'") "'scheme'")))))))))))
