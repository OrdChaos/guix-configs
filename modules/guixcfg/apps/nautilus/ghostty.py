# Repository-owned stub (guixcfg nautilus app, 2026-09).
# Shadows the nautilus-python extension bundled with the saayix ghostty
# package: nautilus-python scans ~/.local/share first and imports modules
# by basename, so this empty module is cached as 'ghostty' and the bundled
# one never loads.  "Open terminal here" is owned exclusively by
# nautilus-open-any-terminal (gsettings terminal fact + new-tab).
# Alternative rejected: patching the ghostty package would rebuild zig.
