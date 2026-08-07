#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-}"
SOURCE_IMAGE="$BUILD_DIR/tokenrouter_monitor.bin"
PROJECT_DESCRIPTION="$BUILD_DIR/project_description.json"
RESOURCE_DIR="$ROOT_DIR/Resources/HardwareFirmware/ESP32-S3-RLCD-4.2"
RESOURCE_IMAGE="$RESOURCE_DIR/tokenrouter_monitor.bin"
MANIFEST="$RESOURCE_DIR/manifest.json"

if [[ -z "$BUILD_DIR" || ! -f "$SOURCE_IMAGE" || ! -f "$PROJECT_DESCRIPTION" ]]; then
  echo "用法：$0 <ESP-IDF 构建目录>" >&2
  exit 1
fi

FIRMWARE_VERSION="$(/usr/bin/plutil -extract project_version raw -o - "$PROJECT_DESCRIPTION")"
MONITOR_PROTOCOL_VERSION="$(/usr/bin/sed -nE \
  's/.*protocolVersion: UInt8 = ([0-9]+).*/\1/p' \
  "$ROOT_DIR/Sources/Sub2APIStatusCore/HardwareMonitorBLEProtocol.swift" | /usr/bin/head -n 1)"
UPDATE_PROTOCOL_VERSION="$(/usr/bin/sed -nE \
  's/.*protocolVersion: UInt8 = ([0-9]+).*/\1/p' \
  "$ROOT_DIR/Sources/Sub2APIStatusCore/HardwareFirmwareUpdate.swift" | /usr/bin/head -n 1)"
IMAGE_SIZE="$(/usr/bin/stat -f '%z' "$SOURCE_IMAGE")"
IMAGE_SHA256="$(LC_ALL=C /usr/bin/shasum -a 256 "$SOURCE_IMAGE" | /usr/bin/awk '{print $1}')"

mkdir -p "$RESOURCE_DIR"
cp "$SOURCE_IMAGE" "$RESOURCE_IMAGE"

TEMP_MANIFEST="$MANIFEST.tmp"
cat > "$TEMP_MANIFEST" <<JSON
{
  "schema_version": 1,
  "hardware_model": "ESP32-S3-RLCD-4.2",
  "firmware_version": "$FIRMWARE_VERSION",
  "monitor_protocol_version": $MONITOR_PROTOCOL_VERSION,
  "update_protocol_version": $UPDATE_PROTOCOL_VERSION,
  "file_name": "tokenrouter_monitor.bin",
  "size": $IMAGE_SIZE,
  "sha256": "$IMAGE_SHA256"
}
JSON
mv "$TEMP_MANIFEST" "$MANIFEST"

"$ROOT_DIR/scripts/verify-hardware-firmware.sh" "$RESOURCE_DIR"
echo "$RESOURCE_DIR"
