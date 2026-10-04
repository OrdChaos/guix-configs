;;; carapace application unit：Carapace（多 shell 命令补全引擎）。
;;;
;;; 来源：carapace-bin 来自自建 virelith channel
;;; （(virelith packages carapace)，v1.8.0，Go force_all 全 completer
;;; 编译）。唯一消费方是 nushell——补全集成放在
;;; (guixcfg apps nushell) 的 config.nu（runtime 生成 + guard），本
;;; 单元只声明 package。
;;;
;;; 不做 persistence（AGENTS.md §12 mixed container / dual authority）：
;;; carapace 的运行期状态都在 $XDG_CONFIG_HOME 派生路径下，与「spec
;;; 从仓库派生」互斥，故一律不 bind：
;;;   ~/.cache/carapace       补全缓存（ephemeral，可重建）
;;;   ~/.config/carapace/
;;;     overlays/             carapace 每次运行自动创建（ephemeral）
;;;     specs/                若启用，由仓库经 home-files 声明式安装
;;;                           （store 软链），因此绝不能持久化该目录，
;;;                           否则 bind 会遮蔽 repo-owned specs。
;;;
;;; spec 分发能力（当前不分发：用户暂无自定义 spec）：
;;;   把 specs/<name>.yaml colocate 到本目录，经 home-files 安装到
;;;   .config/carapace/specs/<name>.yaml。carapace 只从
;;;   $XDG_CONFIG_HOME/carapace/specs 读取（pinned carapace-bin
;;;   cmd/carapace/cmd/completers/completers.go AddSpecs 实测；无
;;;   XDG_CONFIG_DIRS 或 env 覆盖），os.ReadDir/os.ReadFile 跟随
;;;   符号链接（pkg/completer/read.go）；文件名必须满足
;;;   ^[^.]+\.yaml$ 且 basename == spec 的 name 字段，否则报错。
;;;
;;; 明确不做：CARAPACE_BRIDGES（本机只装 bash 且无 bash-completion，
;;; fish/zsh/inshellisense 均不存在——没有可桥接的补全源，纯增复杂度
;;; 与缓存陈旧面）；bash 集成；修改 virelith 的 carapace 包。

(define-module (guixcfg apps carapace definition)
  #:use-module (guix records)
  #:use-module (virelith packages carapace) ;carapace-bin
  #:use-module (guixcfg apps model)
  #:export (%carapace))

(define %carapace
  (application (name 'carapace)
               (home-packages (list carapace-bin))))
