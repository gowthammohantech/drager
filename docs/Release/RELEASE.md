# Build and Release Instructions

Credentials are never stored in the repository. Certificates, provisioning profiles and notarization passwords stay in the keychain or CI secrets.

## Local developer builds
See `docs/DEVELOPER_SETUP.md`. Debug builds use automatic signing with your development team.

## iOS: TestFlight
1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig`.
2. Create the App ID `com.gowthammohan.drager.ios` in App Store Connect (or your prefix).
3. Xcode › SpatialBridge-iOS › Any iOS Device › Product › Archive › Distribute App › App Store Connect › Upload. CLI equivalent:
   ```sh
   xcodebuild -workspace SpatialBridge.xcworkspace -scheme SpatialBridge-iOS -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/SpatialBridge-iOS.xcarchive -allowProvisioningUpdates archive
   xcodebuild -exportArchive -archivePath build/SpatialBridge-iOS.xcarchive -exportPath build/ios \
     -exportOptionsPlist <plist with method=app-store-connect> -allowProvisioningUpdates
   ```
4. Answer export compliance: the app uses only standard OS encryption (`ITSAppUsesNonExemptEncryption = NO` is set). Confirm this for your jurisdiction.
5. App Privacy: no data collected (no tracking, no off-device analytics).

## macOS: development distribution
Run from Xcode, or archive with `Development` signing for testers whose Macs are registered in your team.

## macOS: Developer ID signing and notarization
Requires a paid membership and a "Developer ID Application" certificate in the login keychain.
```sh
Scripts/archive-macos.sh build/release            # archive + export (developer-id)
xcrun notarytool store-credentials spatialbridge --apple-id <id> --team-id <team>   # once
SB_NOTARY_PROFILE=spatialbridge Scripts/notarize-macos.sh build/release/SpatialBridge-macOS.app
```
The app is sandboxed with hardened runtime. The entitlements are network client/server, user-selected read-write and app-scoped bookmarks.

## Mac App Store
The sandboxed configuration is App Store compatible. Archive and use Distribute App › App Store Connect.

## Production release checklist
Follow `docs/RELEASE_CHECKLIST.md`.

## CI
`.github/workflows/ci.yml` runs lint, secret scan, package tests and unsigned app builds on every push. Tagging `v*` runs the release job, which needs these repository secrets: `MACOS_DEVELOPER_ID_P12_BASE64`, `MACOS_DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD`.
