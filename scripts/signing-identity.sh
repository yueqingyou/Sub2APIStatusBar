#!/usr/bin/env bash
set -euo pipefail

find_developer_id_identity() {
  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F\" '/Developer ID Application/ { print $2; exit }'
}
