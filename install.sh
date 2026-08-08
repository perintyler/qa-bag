#!/usr/bin/env bash
#
# Install the `qa` command by symlinking bin/qa onto your PATH.
#
# Usage: ./install.sh            # installs to ~/.local/bin
#        QA_INSTALL_DIR=/usr/local/bin ./install.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${QA_INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"
ln -sf "$SCRIPT_DIR/bin/qa" "$INSTALL_DIR/qa"

echo "Installed: $INSTALL_DIR/qa -> $SCRIPT_DIR/bin/qa"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "Note: $INSTALL_DIR is not on your PATH — add it to your shell profile." ;;
esac
