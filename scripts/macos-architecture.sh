#!/usr/bin/env bash

normalize_macos_architecture() {
  case "$1" in
    x86_64|x64|amd64)
      echo "x86_64"
      ;;
    arm64|aarch64)
      echo "arm64"
      ;;
    universal|universal2)
      echo "universal"
      ;;
    *)
      echo "Unsupported macOS architecture: $1" >&2
      return 1
      ;;
  esac
}

resolve_macos_architecture() {
  local requested="${1:-native}"
  if [[ "$requested" == "native" ]]; then
    normalize_macos_architecture "$(uname -m)"
  else
    normalize_macos_architecture "$requested"
  fi
}
