#!/usr/bin/env bash
# Verifies the toolchain and resolves the local package. Safe to re-run.
source "$(dirname "$0")/_common.sh"
echo "==> Xcode: $(xcodebuild -version | head -1)"
echo "==> Swift: $(swift --version 2>&1 | head -1)"
if [[ ! -f "$REPO_ROOT/Config/Local.xcconfig" ]]; then
  echo "==> No Config/Local.xcconfig (optional). Copy Config/Local.xcconfig.example to override the signing team."
fi
(cd "$PACKAGE_DIR" && swift package resolve)
xcodebuild -list -workspace "$WORKSPACE" >/dev/null
echo "==> Ready. Open SpatialBridge.xcworkspace."
