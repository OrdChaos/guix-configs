# env.nu — repository-owned declarative environment configuration.
# Distributed by guix-configs (modules/guixcfg/apps/nushell/definition.scm).
#
# GPG/pinentry 的 tty 转发（2026-09 VM 实测根因）：git 签名时以
# pipe_command 喂数据给 gpg——gpg 的 fd0 是管道，ttyname(0) 回退
# 失效；只有环境变量 GPG_TTY 能经 OPTION ttyname 到达 agent。
# Wayland-only 会话（无 DISPLAY）时 pinentry-gtk-2 退回 curses 在
# 终端里画密码框，没有 GPG_TTY 就无处可画，签名失败
# "Inappropriate ioctl for device"。tty 是 per-shell 动态事实：
# 每次 nu 启动时求值（do -i 容忍无 tty 上下文），不能进静态
# home-environment-variables。
let _gpg_tty = (do -i { ^tty | str trim })
if not ($_gpg_tty | is-empty) {
    $env.GPG_TTY = $_gpg_tty
}
