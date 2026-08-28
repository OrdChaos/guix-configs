;;; ghostty application unit：terminal（niri bind Mod+T spawn ghostty）。
;;;
;;; 来源（pinned saayix c732c81 审计）：(saayix packages terminals) 的
;;; `ghostty`（稳定版 1.3.1，zig-build-system；`ghostty-latest` 是
;;; master 构建，不采用）。
;;;
;;; 本地 patch（ghostty/fixed，2026-08-23）：上游 build.zig
;;; （src/build/GhosttyResources.zig addLinuxAppResources）在配置期
;;; 把 b.install_prefix 烤进 desktop / dbus service 模板（@GHOSTTY@ →
;;; "{install_prefix}/bin/ghostty"）；Guix zig-build-system 以
;;; DESTDIR=out 分段安装、saayix 传 --prefix . 做 staging，模板替换
;;; 拿到相对路径——装出的 desktop / dbus service 里 Exec=./bin/ghostty
;;; 是 launcher 无法解析的相对路径，desktop 文件打不开 ghostty。
;;; install 后改写为绝对 store 路径。上游修复后本 patch 可移除。
;;;
;;; 配置：声明式（derived state，不持久化）——config.ghostty 经
;;; home-files-service-type（".config/" 显式前缀）生成
;;; ~/.config/ghostty/config.ghostty（ghostty 官方读取路径），
;;; source-relative local-file colocate 本目录；字体族引用既有字体

(define-module (guixcfg apps ghostty definition)
               #:use-module (gnu home services)      ; home-files-service-type
               #:use-module (gnu services)           ; simple-service
               #:use-module (guix gexp)              ; local-file
               #:use-module (guix packages)          ; package/inherit
               #:use-module (guix records)
               #:use-module (guix utils)             ; substitute-keyword-arguments
               #:use-module (saayix packages terminals) ; ghostty
               #:use-module (guixcfg apps model)
               #:export (%ghostty))

(define ghostty/fixed
  (package/inherit ghostty
                   (arguments
                    (substitute-keyword-arguments (package-arguments ghostty)
                                                  ((#:phases phases)
                                                   #~(modify-phases #$phases
                                                                    (add-after 'install 'fix-freedesktop-exec-paths
                                                                               (lambda _
                                                                                 ;; substitute* 由包自带 #:modules 的 (guix build utils) 提供。
                                                                                 (let ((exe (string-append #$output "/bin/ghostty")))
                                                                                   (substitute*
                                                                                    (list (string-append
                                                                                           #$output
                                                                                           "/share/applications/com.mitchellh.ghostty.desktop")
                                                                                          (string-append
                                                                                           #$output
                                                                                           "/share/dbus-1/services/com.mitchellh.ghostty.service"))
                                                                                    (("\\./bin/ghostty") exe)))))))))))

(define %ghostty
  (application
   (name 'ghostty)
   (home-packages (list ghostty/fixed))
   (home-services
    (list (simple-service 'ghostty-config
                          home-files-service-type
                          `((".config/ghostty/config.ghostty"
                             ,(local-file "config.ghostty"
                                          "ghostty-config.ghostty"))))))))
