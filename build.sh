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
# Firma: ad-hoc por defecto (sin cuenta de desarrollador asociada: en otros
# Macs no pide iniciar sesion). Para desarrollo local puedes firmar con tu
# identidad Apple Development para que el permiso de Accesibilidad
# sobreviva entre compilaciones:
#   CODESIGN_IDENTITY="Apple Development: tu@email.com" ./build.sh
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" --force dist/NaturalScrollToggle.app
else
    codesign --sign - --force dist/NaturalScrollToggle.app
fi
echo "Firmado con: ${IDENTITY:-ad-hoc}"

lipo -info dist/NaturalScrollToggle.app/Contents/MacOS/NaturalScrollToggle | head -1
echo "Listo: dist/NaturalScrollToggle.app"
