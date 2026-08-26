# config.nu — repository-owned declarative configuration.
# Distributed by guix-configs (modules/guixcfg/apps/nushell/definition.scm).
#
# Mutable runtime state is kept out of this directory:
#   history  -> ~/.local/state/nushell/history.txt
#               ($env.config.history.path points at the state DIRECTORY;
#                nushell 0.115.1 appends the file name when the custom
#                path is a directory — crates/nu-protocol/src/config/
#                history.rs file_path(); the directory is the
#                application-persistence bind target, so it always
#                exists and ~/.config/nushell/ stays purely declarative)
#   plugin registry -> ~/.config/nushell/plugin.msgpackz (regenerable,
#               intentionally NOT persisted; re-run `plugin add` after loss)
#
# No other preferences are declared yet (no aliases/prompt/theme).

$env.config.history.path = ($env.HOME | path join ".local/state/nushell")
$env.config.show_banner = false

# Theme
use std/config light-theme
use ./theme.nu *
$env.config.color_config = (
    light-theme
    | merge $nu_theme
)
$env.LS_COLORS = (ls-colors)
$env.config.ls.use_ls_colors = true
$env.config.highlight_resolved_externals = true

# starship
mkdir ($nu.data-dir | path join "vendor/autoload")
starship init nu | save -f ($nu.data-dir | path join "vendor/autoload/starship.nu")
