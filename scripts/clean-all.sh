#!/bin/bash
# Natural Scroll Toggle — complete cleanup
# Removes the app (every known location), the LaunchAgent, preferences,
# logs, support files, the Accessibility (TCC) permission, pkg receipts,
# and leftovers of the old auto-switcher. Safe to run when nothing is
# installed: every step is best-effort. Some steps may need admin rights;
# if so, the script prints the exact sudo command to run.
set -u

BUNDLE_ID="com.wilde.naturalscrolltoggle"
PKG_ID="com.wilde.naturalscrolltoggle.pkg"
OLD_LABEL="com.wilde.mouse-scroll-autoswitch"

echo "== Stopping the app and unloading agents"
killall NaturalScrollToggle 2>/dev/null && echo "  [ok] app stopped" || echo "  [skip] app was not running"
launchctl unload "$HOME/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist" 2>/dev/null \
    && echo "  [ok] agent unloaded" || true
launchctl unload "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" 2>/dev/null && echo "  [ok] old agent unloaded" || true

echo "== Removing LaunchAgents (all users)"
for d in /Users/*; do
    [ -d "$d" ] || continue
    pl="$d/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist"
    [ -f "$pl" ] || continue
    if [ "$d" = "$HOME" ]; then
        rm -f "$pl" && echo "  [ok] $pl"
    else
        echo "  [!] other user's agent: sudo rm -f '$pl'"
    fi
done

echo "== Removing the app (all copies)"
found=0
try_remove() {
    [ -d "$1" ] || return
    found=1
    if rm -rf "$1" 2>/dev/null; then
        echo "  [ok] removed $1"
    else
        echo "  [!] needs admin: sudo rm -rf '$1'"
    fi
}
try_remove "/Applications/NaturalScrollToggle.app"
try_remove "$HOME/Applications/NaturalScrollToggle.app"
try_remove "$HOME/projects/natural-scroll-toggle/dist/NaturalScrollToggle.app"
while read -r p; do
    try_remove "$p"
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
[ "$found" = "1" ] || echo "  [skip] no copies found"

echo "== Removing preferences, logs and support files"
defaults delete com.wilde.naturalscrolltoggle 2>/dev/null && echo "  [ok] preferences" || echo "  [skip] no preferences"
rm -rf "$HOME/Library/Application Support/natural-scroll-toggle" 2>/dev/null && echo "  [ok] support files" || echo "  [skip] no support files"
rm -f "$HOME/Library/Logs/natural-scroll-toggle.log" 2>/dev/null && echo "  [ok] log" || echo "  [skip] no log"

echo "== Resetting the Accessibility permission"
tccutil reset Accessibility com.wilde.naturalscrolltoggle 2>/dev/null \
    && echo "  [ok] TCC reset" || echo "  [skip] no TCC entry"

echo "== Forgetting pkg receipts"
pkgutil --forget "$PKG_ID" 2>/dev/null && echo "  [ok] receipt forgotten" || echo "  [skip] no receipt (or needs admin)"

echo "== Removing old auto-switcher leftovers"
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
rm -rf "$HOME/Library/Application Support/mouse-scroll-autoswitch"
rm -f "$HOME/Library/Logs/mouse-scroll-autoswitch.log"
echo "  [ok] done"

echo
echo "Cleanup finished. If any [!] appeared, run the sudo command it shows."
