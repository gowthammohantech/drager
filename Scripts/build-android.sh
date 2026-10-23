#!/usr/bin/env bash
# Builds and tests the Android app, Kotlin core and sb-jvm. Usage: build-android.sh [build|test|lint|all]
# Needs JDK 17 (JAVA_HOME, or Homebrew openjdk@17) and the Android SDK (ANDROID_HOME or local.properties).
source "$(dirname "$0")/_common.sh"
ACTION="${1:-build}"
if [[ -z "${JAVA_HOME:-}" && -d /opt/homebrew/opt/openjdk@17 ]]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17
fi
case "$ACTION" in
  build) TASKS=(:core:assemble :cli:installDist :app:assembleDebug) ;;
  test) TASKS=(:core:test :app:testDebugUnitTest) ;;
  lint) TASKS=(:app:lintDebug) ;;
  all) TASKS=(:core:test :cli:installDist :app:assembleDebug :app:testDebugUnitTest :app:lintDebug) ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac
cd "$REPO_ROOT/Apps/SpatialBridge-Android"
./gradlew "${TASKS[@]}"
