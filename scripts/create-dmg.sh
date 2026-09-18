#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${APP_VERSION:-0.1.0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DMG_PATH="$DIST_DIR/AIUsageBar-$APP_VERSION.dmg"

rm -f "$DMG_PATH"
hdiutil create -volname "AI Usage Bar" -srcfolder "$DIST_DIR/AIUsageBar.app" -ov -format UDZO "$DMG_PATH"
echo "Created $DMG_PATH"
