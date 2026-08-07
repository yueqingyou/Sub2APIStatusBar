#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="${1:-$ROOT_DIR/Resources/HardwareFirmware/ESP32-S3-RLCD-4.2}"
MANIFEST="$RESOURCE_DIR/manifest.json"

[[ -f "$MANIFEST" ]] || {
  echo "缺少硬件固件清单：$MANIFEST" >&2
  exit 1
}

manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

SCHEMA_VERSION="$(manifest_value schema_version)"
HARDWARE_MODEL="$(manifest_value hardware_model)"
FIRMWARE_VERSION="$(manifest_value firmware_version)"
MONITOR_PROTOCOL_VERSION="$(manifest_value monitor_protocol_version)"
UPDATE_PROTOCOL_VERSION="$(manifest_value update_protocol_version)"
FILE_NAME="$(manifest_value file_name)"
EXPECTED_SIZE="$(manifest_value size)"
EXPECTED_SHA256="$(manifest_value sha256 | /usr/bin/tr '[:upper:]' '[:lower:]')"
EXPECTED_MONITOR_PROTOCOL="$(/usr/bin/sed -nE \
  's/.*protocolVersion: UInt8 = ([0-9]+).*/\1/p' \
  "$ROOT_DIR/Sources/Sub2APIStatusCore/HardwareMonitorBLEProtocol.swift" | /usr/bin/head -n 1)"
EXPECTED_UPDATE_PROTOCOL="$(/usr/bin/sed -nE \
  's/.*protocolVersion: UInt8 = ([0-9]+).*/\1/p' \
  "$ROOT_DIR/Sources/Sub2APIStatusCore/HardwareFirmwareUpdate.swift" | /usr/bin/head -n 1)"

[[ "$SCHEMA_VERSION" == "1" ]] || {
  echo "不支持的固件清单版本：$SCHEMA_VERSION" >&2
  exit 1
}
[[ "$HARDWARE_MODEL" == "ESP32-S3-RLCD-4.2" ]] || {
  echo "固件硬件型号不匹配：$HARDWARE_MODEL" >&2
  exit 1
}
[[ "$FIRMWARE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "固件版本格式无效：$FIRMWARE_VERSION" >&2
  exit 1
}
IFS='.' read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<< "$FIRMWARE_VERSION"
for VERSION_PART in "$VERSION_MAJOR" "$VERSION_MINOR" "$VERSION_PATCH"; do
  (( 10#$VERSION_PART <= 255 )) || {
    echo "固件版本分量超出单字节范围：$FIRMWARE_VERSION" >&2
    exit 1
  }
done
[[ "$MONITOR_PROTOCOL_VERSION" == "$EXPECTED_MONITOR_PROTOCOL" ]] || {
  echo "固件监控协议与源码不一致：$MONITOR_PROTOCOL_VERSION != $EXPECTED_MONITOR_PROTOCOL" >&2
  exit 1
}
[[ "$UPDATE_PROTOCOL_VERSION" == "$EXPECTED_UPDATE_PROTOCOL" ]] || {
  echo "固件升级协议与源码不一致：$UPDATE_PROTOCOL_VERSION != $EXPECTED_UPDATE_PROTOCOL" >&2
  exit 1
}
[[ "$FILE_NAME" == "$(basename "$FILE_NAME")" && "$FILE_NAME" != "." && "$FILE_NAME" != ".." ]] || {
  echo "固件文件名不安全：$FILE_NAME" >&2
  exit 1
}

IMAGE="$RESOURCE_DIR/$FILE_NAME"
[[ -f "$IMAGE" ]] || {
  echo "缺少硬件固件镜像：$IMAGE" >&2
  exit 1
}
ACTUAL_SIZE="$(/usr/bin/stat -f '%z' "$IMAGE")"
ACTUAL_SHA256="$(LC_ALL=C /usr/bin/shasum -a 256 "$IMAGE" | /usr/bin/awk '{print $1}')"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] || {
  echo "固件大小不匹配：$ACTUAL_SIZE != $EXPECTED_SIZE" >&2
  exit 1
}
[[ "$ACTUAL_SHA256" == "$EXPECTED_SHA256" ]] || {
  echo "固件 SHA-256 不匹配" >&2
  exit 1
}

IMAGE_MAGIC="$(/bin/dd if="$IMAGE" bs=1 skip=0 count=1 2>/dev/null | /usr/bin/xxd -p)"
APP_DESCRIPTION_MAGIC="$(/bin/dd if="$IMAGE" bs=1 skip=32 count=4 2>/dev/null | /usr/bin/xxd -p)"
EMBEDDED_VERSION="$(/bin/dd if="$IMAGE" bs=1 skip=48 count=32 2>/dev/null | /usr/bin/tr -d '\000')"
EMBEDDED_PROJECT="$(/bin/dd if="$IMAGE" bs=1 skip=80 count=32 2>/dev/null | /usr/bin/tr -d '\000')"
[[ "$IMAGE_MAGIC" == "e9" && "$APP_DESCRIPTION_MAGIC" == "3254cdab" ]] || {
  echo "固件不是有效的 ESP 应用镜像" >&2
  exit 1
}
[[ "$EMBEDDED_PROJECT" == "tokenrouter_monitor" ]] || {
  echo "固件内嵌项目名不匹配：$EMBEDDED_PROJECT" >&2
  exit 1
}
[[ "$EMBEDDED_VERSION" == "$FIRMWARE_VERSION" ]] || {
  echo "固件内嵌版本不匹配：$EMBEDDED_VERSION != $FIRMWARE_VERSION" >&2
  exit 1
}

echo "硬件固件已验证：$FIRMWARE_VERSION，$ACTUAL_SIZE 字节，SHA-256 $ACTUAL_SHA256"
