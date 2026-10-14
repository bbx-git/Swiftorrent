#!/bin/sh
# Builds the SwiftPM app in Release, wraps it in a .app and installs it to ~/Applications.
# Works for any app: the name comes from CFBundleExecutable in App/Resources/Info.plist,
# which must match the executable target in Package.swift.
# Usage: Scripts/build.sh
set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

INFO_PLIST="$ROOT_DIR/App/Resources/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "error: missing $INFO_PLIST" >&2
    exit 1
fi
APP_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST")

BUILD_DIR="$ROOT_DIR/.build/output"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

mkdir -p tmp
if ! swift build -c release --product "$APP_NAME" > tmp/build.log 2>&1; then
    grep -E "error:" tmp/build.log | sort -u | head -40
    echo "Build failed, see tmp/build.log" >&2
    exit 1
fi
grep -E "warning:" tmp/build.log | sort -u | head -40 || true

BIN_PATH=$(swift build -c release --show-bin-path)

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
for icon in "$ROOT_DIR"/App/Resources/*.icns; do
    [ -e "$icon" ] && cp "$icon" "$APP_BUNDLE/Contents/Resources/"
done
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"

echo "Packaged $APP_BUNDLE"
echo "Installed $INSTALLED_APP"
