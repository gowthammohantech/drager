#!/usr/bin/env bash
# Builds the iOS app. Usage: build-ios.sh [simulator|device] [Debug|Release]
source "$(dirname "$0")/_common.sh"
TARGET="${1:-simulator}"; CONFIG="${2:-Debug}"
case "$TARGET" in
  simulator) DEST='generic/platform=iOS Simulator' ;;
  device) DEST='generic/platform=iOS' ;;
  *) echo "unknown target $TARGET" >&2; exit 2 ;;
esac
xcb -scheme SpatialBridge-iOS -configuration "$CONFIG" -destination "$DEST" build
