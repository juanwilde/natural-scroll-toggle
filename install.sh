#!/bin/bash
# Installs Natural Scroll Toggle (menu bar toggle for macOS Natural Scrolling)
# into the current user's ~/Applications and registers a LaunchAgent so it
# starts at login. No administrator rights needed.
# Usage: ./install.sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NaturalScrollToggle.app"
APPS_DIR="$HOME/Applications"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_NAME="com.wilde.naturalscrolltoggle.plist"
BIN="$APPS_DIR/$APP_NAME/Contents/MacOS/NaturalScrollToggle"

if [ ! -d "$SRC/dist/$APP_NAME" ]; then
    echo "dist/$APP_NAME not found. Run ./build.sh first." >&2
    exit 1
fi

mkdir -p "$APPS_DIR" "$LAUNCH_AGENTS"

# Remove quarantine flag in case the repo arrived via AirDrop/browser
xattr -dr com.apple.quarantine "$SRC/dist/$APP_NAME" 2>/dev/null || true

rm -rf "$APPS_DIR/$APP_NAME"
cp -R "$SRC/dist/$APP_NAME" "$APPS_DIR/"
chmod +x "$BIN"
codesign --sign - --force "$APPS_DIR/$APP_NAME" 2>/dev/null || true

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
    <true/>
</dict>
</plist>
EOF

launchctl unload "$LAUNCH_AGENTS/$PLIST_NAME" 2>/dev/null || true
launchctl load -w "$LAUNCH_AGENTS/$PLIST_NAME"
sleep 1

echo "Installed to $APPS_DIR/$APP_NAME and started (it will start automatically at login)."
echo "Look for the arrows icon in the menu bar, next to the clock."
echo ""
echo "The first time you toggle, macOS will ask for Accessibility permission"
echo "(System Settings > Privacy & Security > Accessibility) so the app can"
echo "operate the real System Settings switch. Please approve it."
