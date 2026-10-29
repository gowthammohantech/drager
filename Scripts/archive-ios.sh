#!/usr/bin/env bash
# Archives the iOS app and uploads it to App Store Connect (TestFlight).
# Requires the signing team's Apple ID in Xcode > Settings > Accounts and an
# App Store Connect app record for the bundle ID.
# Usage: archive-ios.sh [export|upload] [output-dir]
source "$(dirname "$0")/_common.sh"
MODE="${1:-upload}"; OUT="${2:-$REPO_ROOT/build/release}"
case "$MODE" in export|upload) ;; *) echo "unknown mode $MODE" >&2; exit 2 ;; esac
mkdir -p "$OUT"
ARCHIVE="$OUT/SpatialBridge-iOS.xcarchive"
xcodebuild -workspace "$WORKSPACE" -scheme SpatialBridge-iOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates archive
cat > "$OUT/ExportOptions-iOS.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$MODE</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions-iOS.plist" -allowProvisioningUpdates
echo "==> iOS $MODE done ($OUT)."
