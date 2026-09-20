#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${APP_VERSION:-0.1.0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_NAME="codeBar"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codebar-dmg.XXXXXX")"
STAGING_DIR="$WORK_DIR/source"
RW_DMG="$WORK_DIR/$APP_NAME-rw.dmg"
MOUNT_DIR=""

hdiutil_quiet() {
  hdiutil "$@" 2> >(sed '/^hdiutil: WARNING: .*deprecated/d' >&2)
}

detach_mount() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil_quiet detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil_quiet detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNT_DIR=""
  fi
}

cleanup() {
  detach_mount
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for tool in hdiutil osascript; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[[ -d "$APP_BUNDLE" ]] || { echo "Missing app bundle: $APP_BUNDLE" >&2; exit 1; }
[[ -f "Packaging/Assets/codeBar-dmg-background.png" ]] || {
  echo "Missing DMG background: Packaging/Assets/codeBar-dmg-background.png" >&2
  exit 1
}

rm -f "$DMG_PATH"
mkdir -p "$STAGING_DIR/.background"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
cp Packaging/Assets/codeBar-dmg-background.png "$STAGING_DIR/.background/install-background.png"

content_kb="$(du -sk "$STAGING_DIR" | awk '{print $1}')"
image_mb=$((content_kb / 1024 + 16))
if (( image_mb < 32 )); then image_mb=32; fi
image_mb=$(( (image_mb + 3) / 4 * 4 ))

hdiutil_quiet create -size "${image_mb}m" -fs HFS+ -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" -ov -format UDRW "$RW_DMG" >/dev/null

MOUNT_DIR="$(mktemp -d "$DIST_DIR/dmg-mount.XXXXXX")"
hdiutil_quiet attach "$RW_DMG" -nobrowse -readwrite -mountpoint "$MOUNT_DIR" >/dev/null

osascript scripts/configure-dmg.applescript \
  "$MOUNT_DIR" "$APP_NAME.app" "$MOUNT_DIR/.background/install-background.png"

rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes"
sync
detach_mount

hdiutil_quiet convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
rm -rf "$WORK_DIR"
trap - EXIT
echo "Created $DMG_PATH"
