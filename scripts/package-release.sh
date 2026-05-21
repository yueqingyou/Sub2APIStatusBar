#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sub2APIStatusBar"
VERSION="${VERSION:-v0.1.18}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ARCHIVE_BASE="$APP_NAME-${VERSION#v}-macOS"
ZIP_PATH="$DIST_DIR/$ARCHIVE_BASE.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_IDENTITY="-"
  echo "Packaging an ad-hoc signed release. The app stores tokens in a shared Keychain item to avoid per-update authorization prompts." >&2
fi

cd "$ROOT_DIR"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/scripts/build-app.sh" >/dev/null

rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
(
  cd "$DIST_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ZIP_PATH" "$APP_NAME.app"
)
shasum -a 256 "$ZIP_PATH" > "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
