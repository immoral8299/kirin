#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PlexTray"
PRODUCT_NAME="PlexTray"
FALLBACK_EXECUTABLE_NAME="MenuBarPlexClient"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_STAGING_DIR="$BUILD_DIR/dmg-root"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
INFO_PLIST_TEMPLATE="$ROOT_DIR/Packaging/PlexTray-Info.plist"
INFO_PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICON_SVG_PATH="$ROOT_DIR/Packaging/PlexTray.svg"
ICON_PATH="$RESOURCES_DIR/PlexTray.icns"
ICON_BUILD_SCRIPT="$ROOT_DIR/scripts/build-icns-from-svg.sh"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.plextray.app}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

mkdir -p "$DIST_DIR"
rm -rf "$BUILD_DIR" "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DMG_STAGING_DIR"

echo "Building $APP_NAME release binary"
swift build -c release --product "$PRODUCT_NAME"

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    EXECUTABLE_PATH="$BIN_DIR/$FALLBACK_EXECUTABLE_NAME"
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Could not find built executable in $BIN_DIR" >&2
    exit 1
fi

cp "$INFO_PLIST_TEMPLATE" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST_PATH"

install -m 755 "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"

if [[ ! -x "$ICON_BUILD_SCRIPT" ]]; then
    echo "Could not find executable app icon build script: $ICON_BUILD_SCRIPT" >&2
    exit 1
fi

echo "Generating app icon from SVG"
"$ICON_BUILD_SCRIPT" "$ICON_SVG_PATH" "$ICON_PATH"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string PlexTray.icns" "$INFO_PLIST_PATH" || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile PlexTray.icns" "$INFO_PLIST_PATH"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "Signing $APP_NAME.app"
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "NOTARY_PROFILE requires SIGNING_IDENTITY" >&2
        exit 1
    fi

    echo "Notarizing $APP_NAME.app"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
fi

cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

echo "Creating DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing DMG"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "Built app: $APP_DIR"
echo "Built dmg: $DMG_PATH"
