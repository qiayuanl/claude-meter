#!/bin/bash
# Builds build/ClaudeMeter.app from the release binary and signs it ad hoc.
# Usage: scripts/build-app.sh [--install]
#   --install  copies the app to /Applications (stopping a running copy first) and
#              registers it with LaunchServices. It does not start the app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/ClaudeMeter.app"
case "${1:-}" in
    "") INSTALL=0 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeMeter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMeter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.qiayuanl.ClaudeMeter</string>
    <key>CFBundleName</key>
    <string>ClaudeMeter</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeMeter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

codesign --force -s - --timestamp=none "$APP"
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/ClaudeMeter.app"
    # The app saves state.json on every change, so SIGTERM loses nothing.
    pkill -x ClaudeMeter && sleep 1
    pkill -9 -x ClaudeMeter || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "Installed $DEST"
fi
