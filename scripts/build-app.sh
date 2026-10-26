#!/bin/bash
# Builds build/ClaudeMeter.app from the release binary and signs it ad hoc.
# Usage: [VERSION=x.y.z] [BUILD_NUMBER=n] scripts/build-app.sh [--zip] [--install]
#   VERSION       CFBundleShortVersionString; default `git describe --tags --always`, else 0.0.0; a leading "v" is dropped.
#   BUILD_NUMBER  CFBundleVersion; default 1.
#   --zip         also writes build/ClaudeMeter-<version>.zip and its .sha256.
#   --install     copies the app to /Applications (stopping a running copy first) and
#                 registers it with LaunchServices. It does not start the app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/ClaudeMeter.app"
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL=0 ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

codesign --force -s - --timestamp=none "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [ "$ZIP" = 1 ]; then
    ZIPNAME="ClaudeMeter-$VERSION.zip"
    rm -f "build/$ZIPNAME"
    ditto -c -k --keepParent "$APP" "build/$ZIPNAME"
    (cd build && shasum -a 256 "$ZIPNAME" > "$ZIPNAME.sha256")
    echo "Packed build/$ZIPNAME"
fi

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
