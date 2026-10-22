# Physical-device acceptance (iPhone + Mac)

Run on a real iPhone and a real Mac on the same Wi-Fi. Record each result (PASS/FAIL, date, devices, OS versions, notes) in `docs/TEST_REPORT.md`. Never mark a step PASS unless you performed it.

## Setup
1. `Scripts/build-macos.sh build Release`, then launch `build/DerivedData/Build/Products/Release/SpatialBridge-macOS.app` (or Run from Xcode). Approve the Local Network prompt on the Mac.
2. Install on the iPhone: Xcode › SpatialBridge-iOS scheme › your device › Run, or
   `xcodebuild -workspace SpatialBridge.xcworkspace -scheme SpatialBridge-iOS -destination 'id=<UDID>' -allowProvisioningUpdates build` and then `xcrun devicectl device install app --device <UDID> <path-to>.app`.
3. Mac menu › Choose… a destination folder (for example a new folder on the Desktop).

## Cases
| ID | Steps | Expected |
|---|---|---|
| T-01 | iPhone onboarding › Continue (allow Local Network) › tap the Mac › compare codes › Codes Match on both | Both show "Paired"; iPhone status becomes Connected |
| T-02 | Unpair on both sides, pair again but click "Don't Match" on the Mac | iPhone shows "Pairing didn't complete"; no Mac in Settings; Send disabled |
| T-03 | Pick a photo; drag slowly to the edge and release | Card springs back, "Flick a little faster" hint, nothing sent |
| T-04 | Flick firmly toward the glowing edge | One transfer; Mac overlay slides in from the calibrated edge; one file saved |
| T-05 | Send 1 MiB, 10 MiB, ~100 MiB files (Files app) | Each arrives; `shasum -a 256` on both copies matches; note durations |
| T-06 | During a 100 MiB send, turn off the Mac's Wi-Fi at ~50% | iPhone shows Retrying, then Failed with Retry; no final file on the Mac; after Wi-Fi returns, Retry completes with exactly one file |
| T-07 | Covered by automated test (corruption); optional: none | — |
| T-08 | Quit the Mac app, delete or rename the destination folder, relaunch, send | Mac shows "Access to the destination folder has expired"; iPhone shows E009; choosing a folder again fixes it |
| T-09 | Send the same photo twice | `IMG_xxxx.HEIC` and `IMG_xxxx 2.HEIC`, original unchanged |
| T-10 | Put an app in full screen on the Mac, send; repeat with two displays and the second display chosen in Settings › Arrival | Overlay appears above the full-screen app without taking focus; on the chosen display; otherwise a notification |
| T-11 | On a second iPhone (or after unpairing on the Mac only), try to send | iPhone shows "The device couldn't be verified"; nothing saved |
| T-12 | Quit and relaunch both apps, send | Connects without pairing; transfer succeeds |
| PRD-RM | Turn on Reduce Motion on the Mac and iPhone, send | Static card instead of trajectory; no flying card on iPhone |
| PRD-NET | Disconnect the router's WAN (internet) but keep Wi-Fi up, send | Transfer succeeds |
| PERF | Note discovery time (onboarding → Mac listed), gesture → overlay delay, 10 MiB duration | Targets: <5 s, <150 ms after offer, <5 s |
