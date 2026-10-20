#!/bin/bash
# Crea dist/Lazarus5K.app: un'unica app universale (Apple Silicon + Intel),
# firmata localmente. Da lanciare sul Mac principale, dalla cartella del progetto.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Lazarus5K.app
BIN=()
for ARCH in arm64 x86_64; do
    echo "Compilo per $ARCH…"
    # Un'area di build per architettura: altrimenti i binari si sovrascrivono.
    swift build -c release --product Lazarus5K --arch "$ARCH" --scratch-path ".build/$ARCH"
    BIN+=("$(swift build -c release --arch "$ARCH" --scratch-path ".build/$ARCH" --show-bin-path)/Lazarus5K")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp App/Info.plist "$APP/Contents/Info.plist"
lipo -create "${BIN[@]}" -output "$APP/Contents/MacOS/Lazarus5K"
codesign --force --sign - "$APP"

echo
echo "Pronta: $APP ($(lipo -archs "$APP/Contents/MacOS/Lazarus5K"))"
echo "Copiala in Applicazioni su entrambi i Mac."
