#!/usr/bin/env bash
# Builds (and optionally tests) the macOS app. Usage: build-macos.sh [build|test] [Debug|Release]
source "$(dirname "$0")/_common.sh"
ACTION="${1:-build}"; CONFIG="${2:-Debug}"
xcb -scheme SpatialBridge-macOS -configuration "$CONFIG" -destination 'platform=macOS' "$ACTION"
