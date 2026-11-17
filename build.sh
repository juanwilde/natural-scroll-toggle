#!/bin/bash
# Compila NaturalScrollToggle (binario universal) y lo deja en dist/.
# Requiere Xcode Command Line Tools (swiftc).
set -e

cd "$(dirname "$0")"

echo "Compilando..."
swiftc -O -target arm64-apple-macosx12.0 \
    -framework AppKit -framework ApplicationServices -framework Foundation \
    Sources/main.swift -o /tmp/nst-arm64
swiftc -O -target x86_64-apple-macosx12.0 \
    -framework AppKit -framework ApplicationServices -framework Foundation \
    Sources/main.swift -o /tmp/nst-x86_64
lipo -create /tmp/nst-arm64 /tmp/nst-x86_64 \
    -o dist/NaturalScrollToggle.app/Contents/MacOS/NaturalScrollToggle
rm /tmp/nst-arm64 /tmp/nst-x86_64
chmod +x dist/NaturalScrollToggle.app/Contents/MacOS/NaturalScrollToggle
# Firma: usa la identidad "Apple Development" si existe (los permisos de
# Accesibilidad sobreviven entre compilaciones); si no, firma ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --force dist/NaturalScrollToggle.app
else
    codesign --sign - --force dist/NaturalScrollToggle.app
fi
echo "Firmado con: ${IDENTITY:-ad-hoc}"

lipo -info dist/NaturalScrollToggle.app/Contents/MacOS/NaturalScrollToggle | head -1
echo "Listo: dist/NaturalScrollToggle.app"
