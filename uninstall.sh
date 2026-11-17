#!/bin/bash
# Completely removes Natural Scroll Toggle: the app (both possible install
# locations), the LaunchAgent, preferences, logs, support files and the TCC
# Accessibility permission. Also removes leftovers of the old standalone
# auto-switcher (mouse-scroll-autoswitch) if present.
# Usage: ./uninstall.sh
set -u

ok()   { echo "  [ok] $1"; }
skip() { echo "  [skip] $1"; }

echo "== Stopping and removing the LaunchAgent"
launchctl unload "$HOME/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist" 2>/dev/null \
    && ok "agent unloaded" || skip "agent was not loaded"
killall NaturalScrollToggle 2>/dev/null && ok "app stopped" || skip "app was not running"
rm -f "$HOME/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist" \
    && ok "plist removed"

echo "== Removing the app"
if rm -rf "$HOME/Applications/NaturalScrollToggle.app" 2>/dev/null; then ok "~/Applications copy removed"; else skip "no ~/Applications copy"; fi
if [ -d "/Applications/NaturalScrollToggle.app" ]; then
    if rm -rf "/Applications/NaturalScrollToggle.app" 2>/dev/null; then
        ok "/Applications copy removed"
    else
        echo "  [!] could not remove /Applications/NaturalScrollToggle.app (needs admin). Run: sudo rm -rf /Applications/NaturalScrollToggle.app"
    fi
else
    skip "no /Applications copy"
fi

echo "== Removing preferences, logs and support files"
defaults delete com.wilde.naturalscrolltoggle 2>/dev/null && ok "preferences removed" || skip "no preferences"
rm -rf "$HOME/Library/Application Support/natural-scroll-toggle" && ok "support files removed" || skip "no support files"
rm -f "$HOME/Library/Logs/natural-scroll-toggle.log" && ok "log removed" || skip "no log"
tccutil reset Accessibility com.wilde.naturalscrolltoggle 2>/dev/null && ok "Accessibility permission reset" || skip "no TCC entry to reset"

echo "== Removing old auto-switcher leftovers (mouse-scroll-autoswitch), if any"
launchctl unload "$HOME/Library/LaunchAgents/com.wilde.mouse-scroll-autoswitch.plist" 2>/dev/null && ok "old agent unloaded" || skip "old agent was not loaded"
rm -f "$HOME/Library/LaunchAgents/com.wilde.mouse-scroll-autoswitch.plist"
rm -rf "$HOME/Library/Application Support/mouse-scroll-autoswitch"
rm -f "$HOME/Library/Logs/mouse-scroll-autoswitch.log"
ok "old daemon leftovers removed (if any)"

echo "Done. Everything removed."
