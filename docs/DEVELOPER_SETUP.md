# Developer Setup

## Requirements
- macOS 26 or later with **Xcode 27** (Swift 6.2+). Verified with Xcode 27.0 (27A266a).
- An Apple ID signed in to Xcode. A free personal team works for development.
- Optional: `brew install swiftformat swiftlint` for `Scripts/lint.sh`.

## First build
```sh
git clone <repo> && cd drager
Scripts/bootstrap.sh
open SpatialBridge.xcworkspace
```
Signing defaults to team `TWR2VXDJQB`. To use your own team:
```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
# set SB_DEVELOPMENT_TEAM = YOURTEAMID and optionally SB_BUNDLE_PREFIX_OVERRIDE
```

## Everyday commands
| Task | Command |
|---|---|
| Package unit + integration tests | `Scripts/test-packages.sh` |
| Include real Bonjour tests | `SB_ENABLE_BONJOUR_TESTS=1 Scripts/test-packages.sh` |
| iOS build (simulator / device) | `Scripts/build-ios.sh simulator` / `Scripts/build-ios.sh device` |
| macOS build / tests | `Scripts/build-macos.sh build` / `Scripts/build-macos.sh test` |
| iOS UI tests | `xcodebuild -workspace SpatialBridge.xcworkspace -scheme SpatialBridge-iOS -destination 'platform=iOS Simulator,name=iPhone 17' test` |
| Lint | `Scripts/lint.sh` |

## Running end to end
- Mac: run the `SpatialBridge-macOS` scheme. The app lives in the menu bar (no Dock icon). Choose a destination folder first.
- iPhone: run `SpatialBridge-iOS` on a physical device on the same Wi-Fi (the simulator shares the Mac's network and can also discover the Mac app, which is handy for UI work, but acceptance must use hardware).
- Both apps accept `-ui-testing` (in-memory state, no networking) and the iOS app accepts `-skip-onboarding`.

## Layout
See `AGENTS.md`. Shared logic lives in `Packages/SpatialBridgeKit`; the apps are thin SwiftUI/AppKit shells over `SenderService` / `ReceiverService`.

## Troubleshooting
- **"No profiles were found"**: pass `-allowProvisioningUpdates` (the scripts do) or open the project once in Xcode with your team selected.
- **Nothing discovered**: check the Local Network permission on both devices, turn off VPNs, avoid guest Wi-Fi.
- **Keychain errors in the simulator log**: the app falls back to in-memory secrets for that launch and logs a fault. Pairings won't persist in that case.
