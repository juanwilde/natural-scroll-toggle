#!/bin/bash
# Natural Scroll Toggle - DMG installer
# Double-click me: installs the app into ~/Applications, sets it to start
# at login, and launches it. No administrator rights needed.
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NaturalScrollToggle.app"
APPS_DIR="$HOME/Applications"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_NAME="com.wilde.naturalscrolltoggle.plist"
BIN="$APPS_DIR/$APP_NAME/Contents/MacOS/NaturalScrollToggle"

if [ ! -d "$SRC/$APP_NAME" ]; then
    echo "Could not find $APP_NAME next to this script." >&2
    exit 1
fi

mkdir -p "$APPS_DIR" "$LAUNCH_AGENTS"

echo "Installing Natural Scroll Toggle..."
rm -rf "$APPS_DIR/$APP_NAME"
cp -R "$SRC/$APP_NAME" "$APPS_DIR/"
chmod +x "$BIN"
# Allow the unsigned app to run without a Gatekeeper block
xattr -dr com.apple.quarantine "$APPS_DIR/$APP_NAME" 2>/dev/null || true

cat > "$LAUNCH_AGENTS/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wilde.naturalscrolltoggle</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

launchctl unload "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENTS/$PLIST_NAME"
sleep 1

cat <<'MSG'

Installed! Natural Scroll Toggle starts automatically at login.

NEXT STEPS (important for the toggle to take effect immediately):

1. Look for the arrows icon in the menu bar, next to the clock.
2. The first time it toggles, macOS will ask for Accessibility permission:
   System Settings > Privacy & Security > Accessibility > enable
   "NaturalScrollToggle". (If it is listed but greyed out, remove it with "-"
   and add it again with "+".)
3. If macOS blocked this installer or the app as "unidentified developer":
   System Settings > Privacy & Security > "Open Anyway", or right-click the
   app > Open.

To uninstall: delete the app from ~/Applications and the file
~/Library/LaunchAgents/com.wilde.naturalscrolltoggle.plist
MSG
