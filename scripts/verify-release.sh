#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sub2APIStatusBar"
VERSION="${VERSION:-v0.1.34}"
ARCHITECTURE="${ARCHITECTURE:-native}"
DIST_DIR="$ROOT_DIR/dist"
source "$ROOT_DIR/scripts/macos-architecture.sh"
ARCHITECTURE="$(resolve_macos_architecture "$ARCHITECTURE")"
ZIP_PATH="$DIST_DIR/$APP_NAME-${VERSION#v}-macOS-$ARCHITECTURE.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
VERIFY_DIR="$(mktemp -d /tmp/sub2api-release-verify.XXXXXX)"

cleanup() {
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
(
  cd "$DIST_DIR"
  LC_ALL=C shasum -a 256 -c "$(basename "$CHECKSUM_PATH")"
)
unzip -t "$ZIP_PATH" >/dev/null
unzip -q "$ZIP_PATH" -d "$VERIFY_DIR"
plutil -lint "$VERIFY_DIR/$APP_NAME.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$VERIFY_DIR/$APP_NAME.app"

APP_EXECUTABLE="$VERIFY_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
ACTUAL_ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_EXECUTABLE")"
case "$ARCHITECTURE" in
  x86_64|arm64)
    [[ "$ACTUAL_ARCHITECTURES" == "$ARCHITECTURE" ]] || {
      echo "Expected $ARCHITECTURE archive, found: $ACTUAL_ARCHITECTURES" >&2
      exit 1
    }
    ;;
  universal)
    [[ " $ACTUAL_ARCHITECTURES " == *" x86_64 "* && " $ACTUAL_ARCHITECTURES " == *" arm64 "* ]] || {
      echo "Expected universal archive, found: $ACTUAL_ARCHITECTURES" >&2
      exit 1
    }
    ;;
esac

echo "Release archive verified."
