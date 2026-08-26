# Nushell light theme.
#
# Canonical color palette lives here.  color_config and LS_COLORS are
# derived from this palette so that individual hex values do not need to
# be duplicated across the Nushell configuration.

export const palette = {
    # Standard colors
    blue:      "#356f9c"
    red:       "#b64c57"
    green:     "#4e7751"
    yellow:    "#8a6421"
    cyan:      "#327c8f"
    magenta:   "#665f96"
    white:     "#5b6975"
    black:     "#2a343d"

    # Extended palette
    rosewater: "#9c7429"
    flamingo:  "#c95b65"
    pink:      "#7c75ad"
    mauve:     "#665f96"
    maroon:    "#c95b65"
    peach:     "#9c7429"
    teal:      "#327c8f"
    sky:       "#4a98a9"
    sapphire:  "#5795c1"
    lavender:  "#7c75ad"

    # Text
    text:      "#202930"
    subtext1:  "#5b6975"
    subtext0:  "#6d7a85"

    # Surfaces
    overlay2:  "#6d7a85"
    overlay1:  "#6d7a85"
    overlay0:  "#2a343d"
    surface2:  "#2a343d"
    surface1:  "#2a343d"
    surface0:  "#f7f8f9"
    base:      "#f7f8f9"
    mantle:    "#f7f8f9"
    crust:     "#f7f8f9"
}

# Overrides for Nushell's built-in light theme.
#
# config.nu merges this into `std/config light-theme`, so new Nushell
# color keys will continue to receive sensible upstream defaults.
export const nu_theme = {
    # Table / general values
    separator: $palette.overlay2

    leading_trailing_space_bg: {
        bg: $palette.flamingo
    }

    header: {
        fg: $palette.blue
        attr: b
    }

    empty: $palette.subtext0

    row_index: {
        fg: $palette.subtext0
    }

    hints: $palette.subtext0

    # Primitive values
    bool: $palette.cyan

    int: $palette.mauve
    float: $palette.lavender

    filesize: $palette.blue
    duration: $palette.yellow
    datetime: $palette.mauve
    range: $palette.yellow

    string: $palette.green
    nothing: $palette.subtext0
    binary: $palette.red
    cell-path: $palette.cyan

    # Syntax highlighting
    shape_block: {
        fg: $palette.blue
        attr: b
    }

    shape_bool: $palette.cyan

    shape_custom: {
        fg: $palette.blue
        attr: b
    }

    # External commands: git, cargo, guix, ...
    shape_external: {
        fg: $palette.cyan
        attr: b
    }

    shape_externalarg: $palette.green

    shape_filepath: $palette.blue

    shape_flag: {
        fg: $palette.sapphire
        attr: b
    }

    shape_float: {
        fg: $palette.lavender
        attr: b
    }

    # Parse errors
    shape_garbage: {
        fg: $palette.base
        bg: $palette.red
        attr: b
    }

    shape_globpattern: {
        fg: $palette.teal
        attr: b
    }

    shape_int: {
        fg: $palette.mauve
        attr: b
    }

    # Nushell built-in commands
    shape_internalcall: {
        fg: $palette.blue
        attr: b
    }

    shape_list: $palette.cyan
    shape_literal: $palette.blue
    shape_nothing: $palette.subtext0

    shape_operator: {
        fg: $palette.yellow
        attr: b
    }

    shape_pipe: {
        fg: $palette.mauve
        attr: b
    }

    shape_range: {
        fg: $palette.yellow
        attr: b
    }

    shape_record: $palette.cyan

    shape_signature: {
        fg: $palette.green
        attr: b
    }

    shape_string: $palette.green

    shape_string_interpolation: {
        fg: $palette.cyan
        attr: b
    }

    shape_table: {
        fg: $palette.blue
        attr: b
    }

    shape_variable: $palette.mauve
}

# Convert "#rrggbb" to an LS_COLORS truecolor foreground sequence.
def ansi-fg [hex: string] {
    let value = ($hex | str trim --char "#")

    let r = ($value | str substring 0..1 | into int --radix 16)
    let g = ($value | str substring 2..3 | into int --radix 16)
    let b = ($value | str substring 4..5 | into int --radix 16)

    $"38;2;($r);($g);($b)"
}

# Generate LS_COLORS from the canonical palette.
export def ls-colors [] {
    [
        # Basic filesystem objects
        $"fi=(ansi-fg $palette.text)"
        $"di=01;(ansi-fg $palette.blue)"
        $"ln=(ansi-fg $palette.cyan)"

        # Broken / missing links
        $"or=01;(ansi-fg $palette.red)"
        $"mi=01;(ansi-fg $palette.red)"

        # Executables
        $"ex=01;(ansi-fg $palette.green)"

        # IPC / special files
        $"pi=(ansi-fg $palette.yellow)"
        $"so=(ansi-fg $palette.mauve)"
        $"bd=01;(ansi-fg $palette.yellow)"
        $"cd=01;(ansi-fg $palette.yellow)"

        # Permission-sensitive entries
        $"su=01;(ansi-fg $palette.red)"
        $"sg=01;(ansi-fg $palette.flamingo)"
        $"tw=01;(ansi-fg $palette.mauve)"
        $"ow=01;(ansi-fg $palette.mauve)"
        $"st=(ansi-fg $palette.mauve)"

        # Archives
        $"*.tar=(ansi-fg $palette.red)"
        $"*.tgz=(ansi-fg $palette.red)"
        $"*.gz=(ansi-fg $palette.red)"
        $"*.bz2=(ansi-fg $palette.red)"
        $"*.xz=(ansi-fg $palette.red)"
        $"*.zst=(ansi-fg $palette.red)"
        $"*.zip=(ansi-fg $palette.red)"
        $"*.7z=(ansi-fg $palette.red)"
        $"*.rar=(ansi-fg $palette.red)"

        # C / C++
        $"*.c=(ansi-fg $palette.sapphire)"
        $"*.h=(ansi-fg $palette.sapphire)"
        $"*.cc=(ansi-fg $palette.sapphire)"
        $"*.cpp=(ansi-fg $palette.sapphire)"
        $"*.cxx=(ansi-fg $palette.sapphire)"
        $"*.hpp=(ansi-fg $palette.sapphire)"

        # Rust
        $"*.rs=(ansi-fg $palette.rosewater)"

        # Python
        $"*.py=(ansi-fg $palette.yellow)"

        # JavaScript / TypeScript
        $"*.js=(ansi-fg $palette.yellow)"
        $"*.mjs=(ansi-fg $palette.yellow)"
        $"*.cjs=(ansi-fg $palette.yellow)"
        $"*.ts=(ansi-fg $palette.blue)"
        $"*.tsx=(ansi-fg $palette.blue)"
        $"*.jsx=(ansi-fg $palette.sapphire)"

        # Web
        $"*.html=(ansi-fg $palette.flamingo)"
        $"*.htm=(ansi-fg $palette.flamingo)"
        $"*.css=(ansi-fg $palette.lavender)"
        $"*.scss=(ansi-fg $palette.lavender)"
        $"*.vue=(ansi-fg $palette.teal)"
        $"*.astro=(ansi-fg $palette.mauve)"

        # Shells / Scheme
        $"*.sh=(ansi-fg $palette.green)"
        $"*.bash=(ansi-fg $palette.green)"
        $"*.zsh=(ansi-fg $palette.green)"
        $"*.nu=(ansi-fg $palette.teal)"
        $"*.scm=(ansi-fg $palette.mauve)"

        # Structured configuration
        $"*.json=(ansi-fg $palette.yellow)"
        $"*.jsonc=(ansi-fg $palette.yellow)"
        $"*.toml=(ansi-fg $palette.mauve)"
        $"*.yaml=(ansi-fg $palette.flamingo)"
        $"*.yml=(ansi-fg $palette.flamingo)"
        $"*.xml=(ansi-fg $palette.flamingo)"
        $"*.ini=(ansi-fg $palette.teal)"
        $"*.conf=(ansi-fg $palette.teal)"

        # Text / markup
        $"*.md=(ansi-fg $palette.blue)"
        $"*.markdown=(ansi-fg $palette.blue)"
        $"*.txt=(ansi-fg $palette.subtext1)"

        # Images
        $"*.png=(ansi-fg $palette.lavender)"
        $"*.jpg=(ansi-fg $palette.lavender)"
        $"*.jpeg=(ansi-fg $palette.lavender)"
        $"*.gif=(ansi-fg $palette.lavender)"
        $"*.webp=(ansi-fg $palette.lavender)"
        $"*.avif=(ansi-fg $palette.lavender)"
        $"*.svg=(ansi-fg $palette.lavender)"

        # Audio
        $"*.mp3=(ansi-fg $palette.mauve)"
        $"*.flac=(ansi-fg $palette.mauve)"
        $"*.wav=(ansi-fg $palette.mauve)"
        $"*.ogg=(ansi-fg $palette.mauve)"

        # Video
        $"*.mp4=(ansi-fg $palette.mauve)"
        $"*.mkv=(ansi-fg $palette.mauve)"
        $"*.webm=(ansi-fg $palette.mauve)"
        $"*.mov=(ansi-fg $palette.mauve)"

        # Documents
        $"*.pdf=(ansi-fg $palette.red)"

        # Temporary / backup
        $"*~=(ansi-fg $palette.subtext0)"
        $"*.bak=(ansi-fg $palette.subtext0)"
        $"*.tmp=(ansi-fg $palette.subtext0)"
        $"*.swp=(ansi-fg $palette.subtext0)"
    ]
    | str join ":"
}