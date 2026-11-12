#!/usr/bin/env bash
# Install claude-box on Linux/macOS: symlink into ~/.local/bin and seed the package list.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
command -v docker >/dev/null || command -v podman >/dev/null || { echo "docker or podman not found — install one first" >&2; exit 1; }
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO/claude-box" "$HOME/.local/bin/claude-box"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/claude-box"; mkdir -p "$CONF"
[[ -f "$CONF/packages" ]] || cp "$REPO/packages.default" "$CONF/packages"
[[ -f "$CONF/network" ]] || cp "$REPO/network.default" "$CONF/network"
echo "installed: ~/.local/bin/claude-box   config: $CONF/{packages,network}"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to your PATH";; esac
