#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Sub2APIStatusBar"
VERSION="${VERSION:-v0.1.33}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ARCHITECTURE="${ARCHITECTURE:-native}"
DIST_DIR="$ROOT_DIR/dist"
source "$ROOT_DIR/scripts/macos-architecture.sh"
ARCHITECTURE="$(resolve_macos_architecture "$ARCHITECTURE")"
ARCHIVE_BASE="$APP_NAME-${VERSION#v}-macOS-$ARCHITECTURE"
ZIP_PATH="$DIST_DIR/$ARCHIVE_BASE.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_IDENTITY="-"
  echo "Packaging an ad-hoc signed release. The app stores tokens in a private local credentials file because ad-hoc Keychain ACLs bind to changing code hashes." >&2
fi

cd "$ROOT_DIR"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" ARCHITECTURE="$ARCHITECTURE" \
  "$ROOT_DIR/scripts/build-app.sh" >/dev/null

rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
(
  cd "$DIST_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ZIP_PATH" "$APP_NAME.app"
  LC_ALL=C shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
