#!/bin/bash
# Builds NaturalScrollToggle.pkg in the current directory.
# Needs dist/NaturalScrollToggle.app (run ./build.sh first).
set -e

cd "$(dirname "$0")/.."

APP="${APP_PATH:-dist/NaturalScrollToggle.app}"
[ -d "$APP" ] || { echo "Run ./build.sh first." >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/root/Applications" "$STAGE/scripts"
cp -R "$APP" "$STAGE/root/Applications/"
cp scripts/pkg/postinstall "$STAGE/scripts/postinstall"
[ -f scripts/pkg/preinstall ] && cp scripts/pkg/preinstall "$STAGE/scripts/preinstall"
chmod +x "$STAGE/scripts/"* || true

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0")

rm -f NaturalScrollToggle.pkg
pkgbuild --root "$STAGE/root" \
    --scripts "$STAGE/scripts" \
    --identifier com.wilde.naturalscrolltoggle.pkg \
    --version "$VERSION" \
    --install-location / \
    NaturalScrollToggle.pkg

echo "Created: $(pwd)/NaturalScrollToggle.pkg (v$VERSION, unsigned: right-click > Open, or: sudo installer -pkg NaturalScrollToggle.pkg -target /)"
