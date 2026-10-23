# Spatial Bridge

Pick a photo or file on your iPhone, flick it toward the edge facing your Mac, and watch it land. The file travels over an encrypted local connection and is verified and saved into a folder you chose. No account, no cloud.

| | |
|---|---|
| **iPhone app** | Onboarding, PhotosPicker and Files import, gesture throw surface with haptics, transfer progress, settings |
| **Mac app** | Menu bar utility, pairing approval, destination folder, click-through arrival overlay, notifications, login item |
| **Shared** | `Packages/SpatialBridgeKit`: Bonjour discovery, SAS pairing, TLS-PSK sessions, chunked transfer with SHA-256, gesture engine, calibration |

## Quick start
```sh
Scripts/bootstrap.sh
open SpatialBridge.xcworkspace       # run SpatialBridge-macOS, then SpatialBridge-iOS on an iPhone
Scripts/test-packages.sh             # 138 unit, integration and conformance tests
```
Requires Xcode 27, iOS 26+ and macOS 26+. See [docs/DEVELOPER_SETUP.md](docs/DEVELOPER_SETUP.md).

## Documentation
- Requirements: [BRD](docs/BRD.md) · [PRD](docs/PRD.md) · [FRD](docs/FRD.md) · [TD](docs/TD.md) · [AD](docs/AD.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md) · [Traceability](docs/REQUIREMENTS_TRACEABILITY.md) · [Architecture decisions](docs/ARCHITECTURE_DECISIONS.md) · [Protocol](docs/API/PROTOCOL.md)
- [Test report](docs/TEST_REPORT.md) · [Known limitations](docs/KNOWN_LIMITATIONS.md) · [Security review](docs/Testing/SECURITY_REVIEW.md)
- [Device acceptance plan](Scripts/device-acceptance.md) · [Release instructions](docs/Release/RELEASE.md) · [Release checklist](docs/RELEASE_CHECKLIST.md) · [Release notes](docs/Release/RELEASE_NOTES.md)
- Marketing site: [Website/](Website/README.md)
- Contributor and agent guide: [AGENTS.md](AGENTS.md)

## Cross-platform (in development)
An Android sender and a Windows receiver are being built on the `feature/cross-platform` branch (ADR-013). **Android and Windows are in development and not yet verified on devices.** The Windows app has not run on Windows yet. The supported product is still iPhone → Mac.

| Folder | Contents |
|---|---|
| `Apps/SpatialBridge-Android/` | Kotlin: `core` (protocol), `cli` (`sb-jvm` test CLI), `app` (Jetpack Compose sender) |
| `Apps/SpatialBridge-Windows/` | C# .NET 10: `SpatialBridge.Core`, `SpatialBridge.Cli` (`sb-dotnet`), `SpatialBridge.Platform.Windows`, `SpatialBridge.App` (WinUI 3 tray receiver), tests |
| `Conformance/` | Swift-generated golden vectors, schema, `SwiftHarness` (`sb-swift`), loopback interop matrix |

```sh
Scripts/interop.sh --self                # loopback interop matrix across sb-swift, sb-jvm, sb-dotnet (add --large for 100 MiB)
Scripts/build-android.sh test            # or: build | lint | all
pwsh Scripts/build-windows.ps1 test      # or: build | smoke | all (build and smoke need Windows)
```
See [CONFORMANCE.md](docs/API/CONFORMANCE.md) and the cross-platform sections of the [test report](docs/TEST_REPORT.md).

## Status
All automated tests, builds and UI tests pass. Cross-device acceptance on real hardware is pending (see the test report). Pre-release MVP.
