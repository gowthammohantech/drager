#!/usr/bin/env bash
# Builds sb-swift, sb-jvm and sb-dotnet, then runs the loopback interop matrix.
# Usage: interop.sh [--no-build] [run_matrix.py options: --large --self --pairs a-b,... --only id,...]
# Needs JDK 17 (JAVA_HOME, or Homebrew openjdk@17) and the .NET 10 SDK (PATH, or ~/.dotnet).
source "$(dirname "$0")/_common.sh"
cd "$REPO_ROOT"

BUILD=1
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--no-build" ]]; then BUILD=0; else ARGS+=("$arg"); fi
done

if [[ -z "${JAVA_HOME:-}" && -d /opt/homebrew/opt/openjdk@17 ]]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17
fi
if ! command -v dotnet >/dev/null && [[ -x "$HOME/.dotnet/dotnet" ]]; then
  export PATH="$HOME/.dotnet:$PATH" DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

SWIFT_PKG=Conformance/SwiftHarness
DOTNET_CLI=Apps/SpatialBridge-Windows/src/SpatialBridge.Cli
if [[ "$BUILD" == "1" ]]; then
  echo "== building sb-swift"
  swift build -c release --package-path "$SWIFT_PKG"
  echo "== building sb-jvm"
  (cd Apps/SpatialBridge-Android && ./gradlew --no-daemon -q :cli:installDist)
  echo "== building sb-dotnet"
  dotnet build "$DOTNET_CLI" -c Release -nologo -v quiet
fi

SWIFT_BIN="$(swift build -c release --package-path "$SWIFT_PKG" --show-bin-path)/sb-swift"
exec python3 Conformance/interop/run_matrix.py \
  --swift-bin "$SWIFT_BIN" \
  --jvm-bin Apps/SpatialBridge-Android/cli/build/install/sb-jvm/bin/sb-jvm \
  --dotnet-dll "$DOTNET_CLI/bin/Release/net10.0/sb-dotnet.dll" \
  ${ARGS[@]+"${ARGS[@]}"}
