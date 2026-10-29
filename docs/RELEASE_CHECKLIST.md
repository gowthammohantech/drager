# Release Checklist

| # | Item | Status |
|---|---|---|
| 1 | All package tests pass (`Scripts/test-packages.sh`) | VERIFIED (2026-10-21) |
| 2 | iOS and macOS Release builds succeed | see TEST_REPORT |
| 3 | iOS UI tests pass on simulator | see TEST_REPORT |
| 4 | Physical-device acceptance `Scripts/device-acceptance.md` T-01…T-12 executed and recorded | NOT_STARTED (requires user with devices) |
| 5 | Security review checklist (`docs/Testing/SECURITY_REVIEW.md`) reviewed | IMPLEMENTED |
| 6 | Version and build numbers bumped in `Config/Shared.xcconfig` | IMPLEMENTED (1.0.0 (1), ADR-016) |
| 7 | Privacy manifests and App Privacy answers match behaviour (no collection) | IMPLEMENTED |
| 8 | Local Network usage strings reviewed | IMPLEMENTED |
| 9 | Developer ID archive, notarized, stapled, `spctl` passes | NOT_STARTED (needs Developer ID certificate) |
| 10 | TestFlight build uploaded and smoke-tested | NOT_STARTED (needs App Store Connect app record) |
| 11 | Release notes (`docs/Release/RELEASE_NOTES.md`) updated | IMPLEMENTED |
| 12 | KNOWN_LIMITATIONS reviewed | IMPLEMENTED |
| 13 | Tag `vX.Y.Z`, never commit signing material | — |
