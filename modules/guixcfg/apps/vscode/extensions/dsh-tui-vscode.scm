;;; baobaolaodie.dsh-tui-vscode —— dsh-TUI 的 VS Code 集成。
;;;
;;; 上游扩展把 IDE selection channel 的 lock 和 last-used MRU 固定在
;;; ~/.dsh-tui；这里与 dsh-TUI 的 patch 对齐到 ~/.local/share/dsh-tui。
;;; 用户必须在 VS Code settings 中把 dsh-tui-vscode.command 指向我们的
;;; 声明式 tui profile（见 apps/vscode/settings.json）。

(define-module (guixcfg apps vscode extensions dsh-tui-vscode)
  #:use-module (guix gexp) ;#~ #$
  #:use-module (guix packages) ;base32
  #:use-module (guix utils) ;substitute-keyword-arguments
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (virelith packages vscode-extensions)
  #:export (vscode-extension-dsh-tui-vscode))

(define-public vscode-extension-dsh-tui-vscode
  (let ((base (vscode-marketplace-extension "baobaolaodie"
                                            "dsh-tui-vscode"
                                            "0.7.6"
                                            (base32
                                             "0q219ykhhrylbcdmq4bwniry3nwwbkas71i5vihgx9d4p7wyd578")
                                            #:license license:expat)))
    (package
      (inherit base)
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:phases phases)
          #~(modify-phases #$phases
              (add-after 'unpack 'move-dsh-tui-data-dir
                (lambda _
                  ;; unpack 阶段已 chdir 进 extension/。
                  (substitute* "out/ide/server.js"
                    (("\\.dsh-tui")
                     ".local/share/dsh-tui"))
                  (substitute* "out/sessions.js"
                    (("\\.dsh-tui")
                     ".local/share/dsh-tui")))))))))))
