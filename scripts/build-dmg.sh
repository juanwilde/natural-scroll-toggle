#!/bin/bash
# Builds NaturalScrollToggle.dmg in the current directory.
# Needs dist/NaturalScrollToggle.app (run ./build.sh first).
set -e

cd "$(dirname "$0")/.."

APP="${APP_PATH:-dist/NaturalScrollToggle.app}"
[ -d "$APP" ] || { echo "Run ./build.sh first." >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
cp Install.command "$STAGE/"
cp dmg/README.txt "$STAGE/"
chmod +x "$STAGE/Install.command"
ln -s /Applications "$STAGE/Applications"

rm -f NaturalScrollToggle.dmg
hdiutil create -volname "Natural Scroll Toggle" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    NaturalScrollToggle.dmg

echo "Created: $(pwd)/NaturalScrollToggle.dmg"
