#!/bin/bash
# Compila Molo e crea build/Molo.app. Con --install la copia in ~/Applications e la avvia.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Molo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Molo "$APP/Contents/MacOS/Molo"
# Traduzioni (italiano e inglese).
cp -R Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Molo</string>
    <key>CFBundleDisplayName</key><string>Molo</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>it</string><string>en</string></array>
    <key>CFBundleIdentifier</key><string>local.molo.dock</string>
    <key>CFBundleExecutable</key><string>Molo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Molo mostra il brano di Spotify in riproduzione e ti permette di metterlo in pausa o cambiarlo.</string>
</dict>
</plist>
PLIST

# Firma ad-hoc con un requisito fisso: così macOS riconosce Molo anche dopo un aggiornamento
# e non chiede di nuovo Registrazione schermo e Accessibilità.
codesign --force --sign - -r='designated => identifier "local.molo.dock"' "$APP" >/dev/null
echo "Creata $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x Molo 2>/dev/null || true
    rm -rf "$HOME/Applications/Molo.app"
    cp -R "$APP" "$HOME/Applications/Molo.app"
    open "$HOME/Applications/Molo.app"
    echo "Installata in ~/Applications/Molo.app"
fi
