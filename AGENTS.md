# AGENTS.md: working on Spatial Bridge

Guidance for AI agents and new contributors.

## Layout
- `Packages/SpatialBridgeKit`: one SwiftPM package, one target per module. **Platform-neutral**: never import UIKit, AppKit or SwiftUI here (`Scripts/lint.sh` enforces this).
- `Apps/SpatialBridge-iOS`, `Apps/SpatialBridge-macOS`: thin SwiftUI/AppKit apps. Both projects use file-system-synchronized folders, so new Swift files under the app folder are picked up automatically without editing the `.pbxproj`.
- `Config/*.xcconfig`: all app build settings. Change signing, IDs and deployment targets here, not in the project.
- `Docs/`: tracking docs (plan, traceability, ADRs, test report, limitations, release checklist).
- `docs/`: the original BRD/PRD/FRD/TD/AD requirement documents. Read-only.

## Commands
```sh
Scripts/test-packages.sh                 # all package tests (Swift Testing)
Scripts/build-ios.sh simulator           # or: device
Scripts/build-macos.sh build             # or: test
Scripts/lint.sh
```
CI builds unsigned with `SB_UNSIGNED=1`.

## Rules
- Swift 6 strict concurrency. App targets default to `@MainActor` isolation. Mark non-UI work `nonisolated` or put it in actors.
- Never log file contents, pairing secrets or raw filenames. Use `Redaction.filename(_:)`.
- Never show a success state before the receiver sends `COMMITTED`.
- Status words in docs: `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `IMPLEMENTED`, `VERIFIED`. `VERIFIED` requires an executed test. Physical-device results go in `Docs/TEST_REPORT.md` only after they were actually run.
- Deviations from the requirement docs need an ADR in `Docs/ADR/`.
