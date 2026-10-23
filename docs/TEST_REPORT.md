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

---

# Cross-platform (`feature/cross-platform`), 2026-10-23

Only executed results are recorded here. Environment: macOS host (MacBook Pro, macOS 27.0.1), Xcode 27.0 (27A266a), .NET SDK 10.0.402, JDK 17 (17.0.20.1), Gradle 9.8.2, Android emulator `Pixel_7_Pro` (API 37). **No Windows machine and no physical Android phone has run anything. CI hasn't run** (the push was refused with HTTP 403), so the `android`, `dotnet-core`, `windows` and `interop` jobs have never executed.

## Automated: re-run at HEAD 5e3770f, 2026-10-23
| Suite | Command | Result |
|---|---|---|
| Swift package (unit, integration, conformance vectors) | `Scripts/test-packages.sh` | **138 tests in 26 suites, all passed** (10 test runs). `Bonjour discovery` skipped (`SB_ENABLE_BONJOUR_TESTS` not set). Includes `TLS cipher suite pinning` and `Conformance vector export` (check mode) |
| Kotlin core (`:core:test`) | `./gradlew :core:test --rerun :app:testDebugUnitTest --rerun` (from `build/test-results` XML) | **409 tests, 0 failures, 0 errors, 0 skipped**: vectors 366 (`CodecVectorTest` 154, `CryptoVectorTest` 19, `TransferVectorTest` 193), `SpatialGestureEngineTest` 20, fuzz 13 (`FrameFuzzTest` 6, `ControlMessageFuzzTest` 4, `SanitizerFuzzTest` 3), `LoopbackTest` 4, `PskTlsTest` 3, `LocatorTest` 3 |
| Android app JVM unit tests (`:app:testDebugUnitTest`) | same | **31 tests, 0 failures**: `TxtRecordsTest` 10, `ContentAndGestureTest` 8, `AppModelTest` 7, `TransferUiMapperTest` 5, `ResetEverythingTest` 1 |
| .NET `SpatialBridge.Core.Tests` (macOS) | `dotnet test` | **583 passed, 0 failed, 0 skipped** |
| .NET `SpatialBridge.Platform.Windows.Tests` (macOS) | `dotnet test` | **67 passed, 0 failed, 8 skipped** (75 total). The skipped tests are `[WindowsFact]` (real DPAPI, NTFS MotW, Windows commit, monitor enumeration, Windows loopback integration) |
| Lint | `Scripts/lint.sh` | exit 0. `swiftformat` and `swiftlint` aren't installed and were skipped; the Kotlin/C# logging check ran |

A plain `./gradlew :core:test :app:testDebugUnitTest` was fully up to date (no tests executed), so the counts above come from the `--rerun` invocation.

## Interop matrix (loopback, one Mac), 2026-10-23
`Scripts/interop.sh --self` (100 MiB opt-in skipped):

```
scenario         | swift->swift | swift->dotnet | jvm->swift | jvm->dotnet | jvm->jvm | dotnet->dotnet
-----------------+--------------+---------------+------------+-------------+----------+---------------
pair-approve     | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-after-pair  | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-1B          | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-262143B     | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-262145B     | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-1MiB        | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
send-100MiB      | SKIP         | SKIP          | SKIP       | SKIP        | SKIP     | SKIP
replay           | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
oversize-offer   | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
unsafe-name      | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
denied-type      | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
corrupt-chunk    | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
out-of-order     | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
cancel-mid       | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
stall            | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
unknown-identity | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
pair-reject      | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
staging-purge    | PASS         | PASS          | PASS       | PASS        | PASS     | PASS
after-unpair     | PASS         | PASS          | PASS       | PASS        | PASS     | PASS

108 passed, 0 failed, 6 skipped
```

`Scripts/interop.sh --self --large`: **114 passed, 0 failed, 0 skipped**. `send-100MiB` passed for every pair: swift→swift 0.3 s, swift→dotnet 0.5 s, jvm→swift 1.8 s, jvm→dotnet 1.8 s, jvm→jvm 1.7 s, dotnet→dotnet 1.3 s.

The pairs stand for iPhone→Mac (swift→swift), iPhone→Windows (swift→dotnet), Android→Mac (jvm→swift) and Android→Windows (jvm→dotnet). They are the protocol cores driven by the test CLIs over loopback, not the apps.

### Measurements (`python3 Conformance/interop/perf.py`, loopback, same Mac; not Wi-Fi)
Defaults: 10 and 100 MiB, 2 runs each; throughput is the median (range) while streaming.

| Pair | Size | Throughput (MiB/s) | Wall (s) | Sender peak RSS (MiB) | Receiver peak RSS (MiB) | Receiver baseline (MiB) | OK |
|---|---|---|---|---|---|---|---|
| swift→swift | 10 MiB | 214 (166–263) | 0.1 | 19 | 28 | 20 | PASS |
| swift→swift | 100 MiB | 299 (291–307) | 0.4 | 20 | 47 | 39 | PASS |
| swift→dotnet | 10 MiB | 49 (47–51) | 0.3 | 19 | 74 | 68 | PASS |
| swift→dotnet | 100 MiB | 143 (70–217) | 1.0 | 20 | 77 | 75 | PASS |
| jvm→swift | 10 MiB | 53 (51–55) | 0.5 | 112 | 20 | 16 | PASS |
| jvm→swift | 100 MiB | 66 (66–66) | 1.9 | 313 | 24 | 22 | PASS |
| jvm→dotnet | 10 MiB | 33 (33–33) | 0.6 | 114 | 75 | 68 | PASS |
| jvm→dotnet | 100 MiB | 65 (63–67) | 1.9 | 312 | 78 | 76 | PASS |

- Receiver memory stays flat with file size for both receivers.
- The `sb-jvm` sender's RSS grows with the default heap (112 → 313 MiB). With `--jvm-opts=-Xmx64m` it stays at 107–109 MiB (10 MiB) and 121 MiB (100 MiB), at the same throughput (jvm→swift 56/68 MiB/s, jvm→dotnet 34/65 MiB/s). So the growth is heap the collector didn't reclaim, not retained memory.
- Start-time staging purge (a stale `.sbpart` with an mtime 48 h old, plus a fresh one): `sb-swift serve` and `sb-dotnet serve` both removed the stale file and kept the fresh one.

## Builds, 2026-10-23
| Target | Configuration | Result |
|---|---|---|
| iOS simulator (`SB_UNSIGNED=1 Scripts/build-ios.sh simulator`) | Debug | BUILD SUCCEEDED |
| macOS (`SB_UNSIGNED=1 Scripts/build-macos.sh build`) | Debug | BUILD SUCCEEDED |
| Windows `SpatialBridge.App` (`dotnet build … -p:Platform=x64`) | Debug, x64 | Build succeeded, 0 warnings, 0 errors. **Compile only, on macOS.** WinUI PRI generation, MSIX packaging and running the app need Windows and were not done |

## Recorded from the branch commits, 2026-10-23 (run in this branch, not re-run for this report)
These ran on 2026-10-23 on this host, and the results are quoted from the commit messages. The docs lane did not re-run them.

| Run | Source | Result |
|---|---|---|
| Android emulator E2E (`Pixel_7_Pro` API 37) against `sb-swift serve` via `10.0.2.2` | bdc2c1f (XP2a) | SAS match; 3 MiB send COMMITTED with matching sha256; unsafe type and 0-byte file rejected with E006 |
| Android instrumented UI tests on the emulator | b8fcf6f (XP1 AU), bdc2c1f (XP2a) | 4 instrumented tests pass |
| Android R8 release build + emulator E2E against `sb-swift` | 17149c7 (XP3-H3) | APK 3.3 MB, BouncyCastle JSSE/JCA stripped; E2E passes. Transfer survives activity recreation (test) |
| Android lint | bdc2c1f (XP2a) | clean apart from the bctls `TrustAllX509TrustManager` warnings (see SECURITY_REVIEW) |
| .NET App build for ARM64 | 2b2dfb2 (XP2b) | builds with 0 warnings (on macOS; compile only) |
| TLS suite enforcement | a2f6517 | `TLSCipherSuiteTests` 4/4; included in the 138 re-run above |
| Interop `--self --large` before the H1 scenarios | 77b29d3 (XP2c) | 102/102 (superseded by the 114/114 re-run above) |

The commits don't record an emulator run against `sb-dotnet serve`; Android→Windows is covered only by the jvm→dotnet loopback matrix.

## Not executed
- Anything on Windows: the `[WindowsFact]` tests, the App smoke test (`--smoke-test`), DPAPI, DNS-SD, NTFS commit with MotW, the firewall rule and the overlay.
- Anything on a physical Android phone, including NSD discovery on a real network.
- The cross-platform device matrix in `Scripts/device-acceptance.md` (all four pairs): **NOT_STARTED**.
- CI (push refused with 403).
