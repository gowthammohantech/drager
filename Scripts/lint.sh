#!/usr/bin/env bash
# Formatting/lint gate. Tools are optional locally; CI installs them.
source "$(dirname "$0")/_common.sh"
cd "$REPO_ROOT"
status=0
if command -v swiftformat >/dev/null; then swiftformat --lint . || status=1; else echo "swiftformat not installed; skipping"; fi
if command -v swiftlint >/dev/null; then swiftlint lint --quiet || status=1; else echo "swiftlint not installed; skipping"; fi
# Platform-neutral packages must not import UI frameworks.
if grep -rnE '^\s*(public )?import (UIKit|AppKit|SwiftUI)' Packages/SpatialBridgeKit/Sources; then
  echo "error: UI framework imported in a platform-neutral package" >&2; status=1
fi
# Never commit signing material.
if git ls-files | grep -E '\.(p12|cer|mobileprovision|provisionprofile|p8)$'; then
  echo "error: signing material is tracked by git" >&2; status=1
fi
exit $status
