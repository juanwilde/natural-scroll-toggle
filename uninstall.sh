#!/bin/bash
# Uninstalls Natural Scroll Toggle from the current user.
# Usage: ./uninstall.sh
set -e

PLIST="$HOME/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist"
APP="$HOME/Applications/NaturalScrollToggle.app"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"

echo "Uninstalled."
