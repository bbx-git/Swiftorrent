#!/bin/sh
set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-Release}
BUILD_DIR="$ROOT_DIR/.build/output/$CONFIGURATION"
APP_NAME="Swiftorrent"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$BUILD_DIR/$APP_NAME"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

cd "$ROOT_DIR"

xcodebuild \
    -quiet \
    -scheme "$APP_NAME" \
    -destination 'platform=macOS,arch=arm64' \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$ROOT_DIR/.build/DerivedData" \
    SYMROOT="$ROOT_DIR/.build/output" \
    DSTROOT="$ROOT_DIR/.build/install"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/App/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"

echo "Packaged $APP_BUNDLE"
echo "Installed $INSTALLED_APP"
