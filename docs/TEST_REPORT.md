# Test Report

Only executed results are recorded here. Environment: MacBook Pro, macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4. Simulator: iPhone 17 (iOS 27). Device: iPhone 17 Pro Max "Insane" (iOS 27.0).

## Automated: package (`SB_ENABLE_BONJOUR_TESTS=1 Scripts/test-packages.sh`), 2026-10-21
**113 tests in 23 suites, all passed.**

| Area | Suites | Result |
|---|---|---|
| Models, protocol coding, error codes | Control message coding, Model invariants, Transfer state machine | pass |
| Frame codec (malformed, oversize, partial) | FrameCodecTests | pass |
| Pairing crypto + protocol (T-01, T-02, MITM, spoofed ID, rate limit, version) | Pairing cryptography, Pairing protocol, Identity stores | pass |
| Session authentication (T-11, key mismatch, Mac impersonation) | Session authentication | pass |
| Gesture engine, synthetic traces (T-03, T-04) | SpatialGestureEngineTests | pass |
| Calibration mapping (all edges, origin flip, clamping, display fallback) | CoordinateMapperTests | pass |
| Persistence, diagnostics scrubbing | PersistenceTests, DiagnosticsTests | pass |
| Real Network.framework loopback: pairing → TLS-PSK session → keepalive RTT; unknown/wrong PSK rejected; multi-peer; pairing listener disabled; 10 MiB chunk stream with slow consumer | Network loopback | pass |
| Real Bonjour advertise + browse (both roles merged) | Bonjour discovery | pass, discovered in **0.92 s** |
| Transfer: T-05 1/10/100 MiB over TLS loopback (SHA-256 identical), T-06, T-07, T-08 (package), T-09, traversal, oversize, denied type, disk full, replay, same-ID retry, cancel, spoofed source | File transfer, Storage primitives | pass |
| Services E2E: pair → connect → send with history on both sides, T-12 restart persistence, reconnection, Mac-side unpair revocation, T-02 | Services end to end | pass |

### Measurements (loopback, same Mac; not Wi-Fi)
| Metric | Result |
|---|---|
| T-05 1 MiB / 10 MiB / 100 MiB | 0.03 s / 0.06 s / 0.45 s (≈224 MiB/s) |
| Peak RSS of the test process during the 100 MiB run (includes generating and verifying 111 MiB of fixtures) | 308 MB → **103 MB** after the autorelease fix |
| Bonjour discovery (same host) | 0.92 s |

## Builds, 2026-10-21
| Target | Configuration | Result |
|---|---|---|
| iOS simulator | Debug | BUILD SUCCEEDED |
| iOS device (signed, TWR2VXDJQB) | Debug, Release | BUILD SUCCEEDED |
| macOS (signed, sandboxed, hardened) | Debug, Release | BUILD SUCCEEDED |
| macOS static analysis (`xcodebuild analyze`) | Debug | no analyzer findings |

## UI tests, 2026-10-21
| Suite | Result |
|---|---|
| iOS (iPhone 17 simulator): onboarding → discovery → troubleshooting; home empty/disconnected states; pair sheet searching state; settings sensitivity + calibration; history empty | **5/5 pass** |
| macOS: menu bar extra opens, shows availability, destination and quit controls | **1/1 pass** |

## Physical-device acceptance
- 2026-10-21: the iOS Debug build was **installed** on "Insane" (`xcrun devicectl device install app`, verified in the device app list).
- T-01…T-12 and the PRD scenarios in `Scripts/device-acceptance.md` have **not been executed yet**. They need a person to approve the Local Network prompts, compare pairing codes on both screens, choose the destination folder and perform the throws. Their status stays `IMPLEMENTED` until the results are recorded here.
