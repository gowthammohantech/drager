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

---

# Cross-platform matrix (iPhone or Android → Mac or Windows, ADR-013)

Run all four pairs on one Wi-Fi network that passes mDNS between clients (no guest or client-isolated network). Android and Windows have no AWDL, so a shared infrastructure Wi-Fi is required (KNOWN_LIMITATIONS L-13). Fill in each Pass/Fail cell only after performing the step, then copy the results (date, devices, OS versions, build commit, notes) into `docs/TEST_REPORT.md`. Leave a cell empty if the step wasn't run.

## Setup
1. **Mac:** as in the iPhone + Mac setup above (Release build, Local Network approved, destination folder chosen).
2. **Windows PC: network profile.** Settings › Network & internet › Wi-Fi › (the network) › Network profile type › **Private**. On a Public network the app warns and inbound connections are blocked.
3. **Windows PC: build and install the app** (needs the .NET 10 SDK on Windows). Use one of these:
   - Unpackaged: `pwsh Scripts/build-windows.ps1 build Release` (or `dotnet build Apps/SpatialBridge-Windows/src/SpatialBridge.App -c Release -p:Platform=x64 -r win-x64`), then run `SpatialBridge.App.exe` from the output folder under `Apps/SpatialBridge-Windows/src/SpatialBridge.App/bin/x64/Release/`. The exe is unsigned, so SmartScreen may block it: choose More info › Run anyway.
   - MSIX: add `-p:WindowsPackageType=MSIX` to the build, sign the package with a test certificate the PC trusts, and install it with `Add-AppxPackage`. Only the MSIX install carries the Private-profile firewall rule (`Package.appxmanifest`).
   - Optional sanity check before the matrix: `pwsh Scripts/build-windows.ps1 smoke` (tray launch with the scripted fake).
4. **Windows PC: firewall prompt.** On the first launch of the unpackaged exe, Windows Defender Firewall asks whether to allow `SpatialBridge.App` on networks. Allow **Private** only. If you dismissed it, add an inbound allow rule for the exe on the Private profile.
5. **Windows PC: destination.** Tray icon › Settings › choose a destination folder on an **NTFS** drive (MotW isn't applied on FAT/exFAT or network shares, L-18). Turn on Available and Allow new pairings.
6. **Android phone: debug APK via adb.** Enable Developer options › USB debugging, connect over USB, then `Scripts/build-android.sh build` and `adb install -r Apps/SpatialBridge-Android/app/build/outputs/apk/debug/app-debug.apk`. Launch Spatial Bridge and allow the Nearby devices permission when asked (Android 13+). The phone needs Android 9 (API 28) or newer.
7. **iPhone:** as in the iPhone + Mac setup above.
8. **Test files.** Put these on each phone: a photo or file under 1 MiB, a file near 100 MiB (just under 104 857 600 bytes), and the unsafe files `run.sh` (for → Mac) and `run.sh` plus `setup.exe` (for → Windows; the Mac doesn't deny Windows executables, CONFORMANCE §4). Record `sha256` for the two good files.
9. **Calibration for the overlay check.** Place the phone physically to the **right** of the computer. In the phone app, Calibration › "Right of the computer". The throw then goes toward the phone's left edge, and the card should arrive at the computer's **right** edge.

## Cases (run for every pair)
| ID | Steps | Expected |
|---|---|---|
| XP-DISC | With the receiver Available, open discovery on the phone | The receiver appears within 5 s with the right name and platform; note the time |
| XP-PAIR | Pair from the phone; compare the 6-digit codes on both screens; confirm on both | Codes are identical; both sides show Paired; the phone shows Connected (a first E004 retry right after pairing is acceptable, L-16) |
| XP-SMALL | Send the < 1 MiB file with a gesture | One file saved; success on the phone only after the receiver shows it saved; `sha256` matches |
| XP-LARGE | Send the ~100 MiB file | Arrives with matching `sha256`; note the duration; progress advances; no success state before completion |
| XP-UNSAFE | Send `run.sh` (and `setup.exe` to Windows) | Rejected with E006 on both sides; nothing saved; no success state |
| XP-WIFI | Turn the receiver's Wi-Fi off for ~10 s and back on, then send the small file | The phone shows a reconnecting or failed state, reconnects without pairing again, and the send succeeds with exactly one file |
| XP-UNPAIR | Unpair the phone on the receiver only, then send from the phone | The phone shows "The device couldn't be verified" (E004); nothing saved. Pair again afterwards |
| XP-OVERLAY | With the calibration from setup step 9, throw toward the computer | The arrival card slides in at the **right** edge of the screen and doesn't take focus; on Windows, a notification is acceptable if the overlay can't show (best effort, L-14) |

## Results
Write PASS or FAIL in a cell only after performing the step. On Windows, also check that the saved file has a `Zone.Identifier` stream (`Get-Item <file> -Stream Zone.Identifier`) and note it under XP-SMALL.

### iPhone → Mac (regression)
| ID | Pass/Fail | Notes |
|---|---|---|
| XP-DISC | | |
| XP-PAIR | | |
| XP-SMALL | | |
| XP-LARGE | | |
| XP-UNSAFE | | |
| XP-WIFI | | |
| XP-UNPAIR | | |
| XP-OVERLAY | | |

### iPhone → Windows
| ID | Pass/Fail | Notes |
|---|---|---|
| XP-DISC | | |
| XP-PAIR | | |
| XP-SMALL | | |
| XP-LARGE | | |
| XP-UNSAFE | | |
| XP-WIFI | | |
| XP-UNPAIR | | |
| XP-OVERLAY | | |

### Android → Mac
| ID | Pass/Fail | Notes |
|---|---|---|
| XP-DISC | | |
| XP-PAIR | | |
| XP-SMALL | | |
| XP-LARGE | | |
| XP-UNSAFE | | |
| XP-WIFI | | |
| XP-UNPAIR | | |
| XP-OVERLAY | | |

### Android → Windows
| ID | Pass/Fail | Notes |
|---|---|---|
| XP-DISC | | |
| XP-PAIR | | |
| XP-SMALL | | |
| XP-LARGE | | |
| XP-UNSAFE | | |
| XP-WIFI | | |
| XP-UNPAIR | | |
| XP-OVERLAY | | |
