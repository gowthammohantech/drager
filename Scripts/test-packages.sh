#!/usr/bin/env bash
# Runs all SpatialBridgeKit unit + integration tests (Swift Testing).
# Set SB_ENABLE_BONJOUR_TESTS=1 to include real Bonjour advertise/browse tests.
source "$(dirname "$0")/_common.sh"
cd "$PACKAGE_DIR"
swift build --build-tests
swift test --parallel "$@"
