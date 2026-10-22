#!/usr/bin/env bash
# Archives and exports a Developer ID–signed macOS build.
# Requires a "Developer ID Application" identity in the login keychain.
# Usage: archive-macos.sh [output-dir]
source "$(dirname "$0")/_common.sh"
OUT="${1:-$REPO_ROOT/build/release}"
mkdir -p "$OUT"
ARCHIVE="$OUT/SpatialBridge-macOS.xcarchive"
xcodebuild -workspace "$WORKSPACE" -scheme SpatialBridge-macOS -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates archive
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
echo "==> Exported to $OUT. Next: Scripts/notarize-macos.sh \"$OUT/SpatialBridge-macOS.app\""
