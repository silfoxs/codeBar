#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="AIUsageBar"
APP_VERSION="${APP_VERSION:-0.1.0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ -n "${BUILD_PATH:-}" ]]; then
  swift build -c release --build-path "$BUILD_PATH"
  BIN_DIR="$(swift build -c release --build-path "$BUILD_PATH" --show-bin-path)"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp Packaging/Info.plist "$APP_PATH/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP_PATH/Contents/Info.plist"

# Ad-hoc signing makes a local bundle launchable. Set CODESIGN_IDENTITY to a
# Developer ID identity in CI/release builds for a distributable signature.
codesign --force --sign "$SIGNING_IDENTITY" --entitlements Packaging/AIUsageBar.entitlements "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/$APP_NAME-$APP_VERSION.zip"
echo "Packaged $APP_PATH"
