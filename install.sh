#!/usr/bin/env bash
set -euo pipefail

REPO="tyvsmith/hypr-sticky-hdr"
SCRIPT_NAME="hypr-sticky-hdr"
INSTALL_DIR="$HOME/.local/bin"
AUTOSTART_FILE="$HOME/.config/hypr/autostart.conf"
AUTOSTART_LINE="exec-once = hypr-sticky-hdr daemon"

main() {
    mkdir -p "$INSTALL_DIR"

    # If run from a clone, use the local file; otherwise fetch from GitHub
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/$SCRIPT_NAME" ]]; then
        echo "Installing from local copy..."
        cp "$script_dir/$SCRIPT_NAME" "$INSTALL_DIR/$SCRIPT_NAME"
    else
        echo "Downloading from GitHub..."
        curl -fsSL "https://raw.githubusercontent.com/$REPO/main/$SCRIPT_NAME" \
            -o "$INSTALL_DIR/$SCRIPT_NAME"
    fi

    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    echo "Installed $SCRIPT_NAME to $INSTALL_DIR/"

    # Install example config if no config exists
    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-sticky-hdr"
    if [[ ! -f "$config_dir/config" ]]; then
        mkdir -p "$config_dir"
        if [[ -f "$script_dir/config.example" ]]; then
            cp "$script_dir/config.example" "$config_dir/config.example"
        else
            curl -fsSL "https://raw.githubusercontent.com/$REPO/main/config.example" \
                -o "$config_dir/config.example" 2>/dev/null || true
        fi
    fi

    # Add to Hyprland autostart if not already present
    if [[ -d "$HOME/.config/hypr" ]]; then
        touch "$AUTOSTART_FILE"
        if ! grep -qF "$SCRIPT_NAME daemon" "$AUTOSTART_FILE"; then
            echo "$AUTOSTART_LINE" >> "$AUTOSTART_FILE"
            echo "Added to $AUTOSTART_FILE"
        else
            echo "Already in $AUTOSTART_FILE"
        fi
    else
        echo "Hyprland config not found — add this to your autostart manually:"
        echo "  $AUTOSTART_LINE"
    fi

    # Verify PATH
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
        echo ""
        echo "Warning: $INSTALL_DIR is not in your PATH."
        echo "Add it to your shell config, e.g.:"
        echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    fi

    echo ""
    echo "Done. Start with: hypr-sticky-hdr daemon"
    echo "Optional config:  $config_dir/config"
    echo "Example config:   $config_dir/config.example"
}

main
