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

# carapace external completer (package owned by apps/carapace).
# Generated at runtime, not at build time: `carapace _carapace nushell`
# embeds UserConfigDir into the generated script ($HOME/.config/carapace),
# so a store-backed file would hardcode one user's HOME.  The cache file is
# ephemeral (regenerated below / $nu.cache-dir is not persisted); the guard
# keeps nushell usable if the carapace app is disabled.
if (which carapace | is-not-empty) {
    ^carapace _carapace nushell | save -f ($nu.cache-dir | path join "carapace.nu")
    source ($nu.cache-dir | path join "carapace.nu")
}
