#!/usr/bin/env bash
# Shared helpers for Spatial Bridge scripts. Source, don't execute.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$REPO_ROOT/SpatialBridge.xcworkspace"
PACKAGE_DIR="$REPO_ROOT/Packages/SpatialBridgeKit"
DERIVED_DATA="${SB_DERIVED_DATA:-$REPO_ROOT/build/DerivedData}"

# Pass SB_UNSIGNED=1 (CI) to build without a signing identity.
signing_args() {
  if [[ "${SB_UNSIGNED:-0}" == "1" ]]; then
    echo "CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="
  else
    echo "-allowProvisioningUpdates"
  fi
}

xcb() {
  # shellcheck disable=SC2046
  xcodebuild -workspace "$WORKSPACE" -derivedDataPath "$DERIVED_DATA" "$@" $(signing_args)
}
