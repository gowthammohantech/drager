#!/usr/bin/env bash
# Notarizes and staples a Developer ID–signed app.
# Credentials come from a notarytool keychain profile, never from this repo:
#   xcrun notarytool store-credentials "$SB_NOTARY_PROFILE" --apple-id <id> --team-id <team>
# Usage: SB_NOTARY_PROFILE=spatialbridge notarize-macos.sh path/to/SpatialBridge-macOS.app
source "$(dirname "$0")/_common.sh"
APP="${1:?path to .app required}"
PROFILE="${SB_NOTARY_PROFILE:?set SB_NOTARY_PROFILE to a notarytool keychain profile name}"
ZIP="${APP%.app}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
echo "==> Notarized and stapled: $APP"
