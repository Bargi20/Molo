#!/bin/bash
# Nasconde o ripristina il Dock di Apple.
#   ./scripts/apple-dock.sh hide
#   ./scripts/apple-dock.sh restore
set -euo pipefail

case "${1:-}" in
    hide)
        defaults write com.apple.dock autohide -bool true
        defaults write com.apple.dock autohide-delay -float 1000
        killall Dock
        echo "Dock di Apple nascosto."
        ;;
    restore)
        defaults delete com.apple.dock autohide-delay 2>/dev/null || true
        defaults write com.apple.dock autohide -bool false
        killall Dock
        echo "Dock di Apple ripristinato."
        ;;
    *)
        echo "Uso: $0 hide|restore" >&2
        exit 1
        ;;
esac
