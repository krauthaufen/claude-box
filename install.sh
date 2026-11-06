#!/usr/bin/env bash
# Install claude-box on Linux/macOS: symlink into ~/.local/bin and seed the package list.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
command -v docker >/dev/null || { echo "docker not found — install Docker first" >&2; exit 1; }
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO/claude-box" "$HOME/.local/bin/claude-box"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/claude-box"; mkdir -p "$CONF"
[[ -f "$CONF/packages" ]] || cp "$REPO/packages.default" "$CONF/packages"
echo "installed: ~/.local/bin/claude-box   packages: $CONF/packages"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to your PATH";; esac
