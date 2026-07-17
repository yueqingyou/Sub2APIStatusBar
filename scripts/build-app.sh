#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-v0.1.33}"
APP_NAME="Sub2APIStatusBar"
BUNDLE_ID="${BUNDLE_ID:-com.geekywizkid.sub2api-statusbar}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHITECTURE="${ARCHITECTURE:-native}"
MINIMUM_MACOS_VERSION="${MINIMUM_MACOS_VERSION:-12.0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

source "$ROOT_DIR/scripts/macos-architecture.sh"
ARCHITECTURE="$(resolve_macos_architecture "$ARCHITECTURE")"

build_binary_for_architecture() {
  local architecture="$1"
  local scratch_path="$ROOT_DIR/.build/release-$architecture"
  local triple="$architecture-apple-macosx$MINIMUM_MACOS_VERSION"
  local binary_directory

  swift build \
    -c release \
    --product "$APP_NAME" \
    --triple "$triple" \
    --scratch-path "$scratch_path" >&2
  binary_directory="$(swift build \
    -c release \
    --triple "$triple" \
    --scratch-path "$scratch_path" \
    --show-bin-path)"
  echo "$binary_directory/$APP_NAME"
}

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/generate-icon.swift" >/dev/null

case "$ARCHITECTURE" in
  x86_64|arm64)
    APP_BINARY="$(build_binary_for_architecture "$ARCHITECTURE")"
    ;;
  universal)
    X86_64_BINARY="$(build_binary_for_architecture x86_64)"
    ARM64_BINARY="$(build_binary_for_architecture arm64)"
    ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [[ "$ARCHITECTURE" == "universal" ]]; then
  /usr/bin/lipo -create "$X86_64_BINARY" "$ARM64_BINARY" -output "$MACOS_DIR/$APP_NAME"
else
  cp "$APP_BINARY" "$MACOS_DIR/$APP_NAME"
fi
cp -R "$ROOT_DIR/Resources/." "$RESOURCES_DIR/"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>TokenRouter Monitor</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION#v}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_MACOS_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <true/>
  <key>NSSupportsSuddenTermination</key>
  <true/>
</dict>
</plist>
PLIST

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_DIR"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
fi

ACTUAL_ARCHITECTURES="$(/usr/bin/lipo -archs "$MACOS_DIR/$APP_NAME")"
case "$ARCHITECTURE" in
  x86_64|arm64)
    [[ "$ACTUAL_ARCHITECTURES" == "$ARCHITECTURE" ]] || {
      echo "Expected $ARCHITECTURE app, found: $ACTUAL_ARCHITECTURES" >&2
      exit 1
    }
    ;;
  universal)
    [[ " $ACTUAL_ARCHITECTURES " == *" x86_64 "* && " $ACTUAL_ARCHITECTURES " == *" arm64 "* ]] || {
      echo "Expected universal app, found: $ACTUAL_ARCHITECTURES" >&2
      exit 1
    }
    ;;
esac

echo "$APP_DIR"
