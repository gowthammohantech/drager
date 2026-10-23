# Implementation Plan

Statuses: `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `IMPLEMENTED`, `VERIFIED`. `VERIFIED` means the acceptance criteria were executed successfully. See `TEST_REPORT.md` for evidence.

Architecture summary: two native apps over a shared platform-neutral SwiftPM package (`Packages/SpatialBridgeKit`). The iPhone browses Bonjour, pairs with a SAS-verified X25519 handshake, and then opens TLS 1.2 ECDHE-PSK sessions (suite 0xCCAC) to the Mac. Files stream as bounded binary chunks after a metadata offer. The Mac stages, verifies, atomically commits, and only then confirms (ADR-001…012).

---

## Phase 0: Discovery and feasibility
- **Objective:** understand the requirements, verify the APIs, record decisions.
- **Tasks:** read the BRD/PRD/FRD/TD/AD; verify the APIs against the Xcode 27 SDK (NWListener.Service, NWBrowser Bonjour descriptor, `sec_protocol_options_add_pre_shared_key`, SMAppService.mainApp, MenuBarExtra, PhotosPicker/Transferable, security-scoped bookmarks, sensoryFeedback, NSPanel collection behaviours); write the ADRs and the traceability matrix.
- **Dependencies:** none.
- **Acceptance:** ADRs and traceability exist; the environment builds Swift 6 for iOS 26/macOS 26.
- **Status:** VERIFIED
- **Test results:** toolchain verified (Xcode 27.0 27A266a, Swift 6.4).
- **Risks:** TLS-PSK-only handshake behaviour on device (see KNOWN_LIMITATIONS).

## Phase 1: Foundation
- **Objective:** monorepo, both app targets, shared package, DI, logging, tests, CI; both apps compile.
- **Tasks:** package with 10 targets; models, errors E001–E014, state machines, frame codec, pairing crypto, gesture engine, calibration mapper, persistence, diagnostics, fakes; hand-written Xcode projects (ADR-012); workspace; xcconfigs, entitlements, privacy manifests; Scripts; CI; docs.
- **Dependencies:** Phase 0.
- **Acceptance:** `swift test` passes; iOS (simulator + device) and macOS builds succeed.
- **Status:** VERIFIED
- **Test results:** 73 package tests pass; `xcodebuild` iOS simulator, iOS device (signed, team TWR2VXDJQB) and macOS builds succeed.
- **Risks:** none open.

## Phase 2: Networking
- **Objective:** Bonjour discovery, connection lifecycle, pairing, authenticated encrypted sessions.
- **Tasks:** `NWFrameTransport` (framed NWConnection with backpressure); `BonjourBrowser` (timeout, dedupe, updates); `BridgeListener` (advertise when available, PSK per trusted peer); `PairingSession` initiator/responder state machines over `FrameTransport`; TLS-PSK parameters; reconnect backoff; path monitor.
- **Dependencies:** Phase 1.
- **Acceptance:** loopback pairing end to end; loopback TLS-PSK session exchanges frames; an untrusted PSK identity is rejected (T-11); a pairing rejection persists no trust (T-02).
- **Status:** VERIFIED (automated, loopback + real Bonjour on one Mac). Cross-device verification is part of the Phase 8 device acceptance.
- **Test results:** `PairingProtocolTests` (7), `SessionAuthenticatorTests` (4), `NetworkLoopbackTests` (6), and `BonjourDiscoveryTests` (1, discovered in 0.92 s with `SB_ENABLE_BONJOUR_TESTS=1`) all pass.
- **Risks:** TLS 1.3 PSK unsupported, so TLS 1.2 ECDHE-PSK is used (ADR-010). Local Network prompt behaviour on device is still unverified.

## Phase 3: File transfer
- **Objective:** offer → accept → stream → verify → commit, with cancellation and retry.
- **Tasks:** `TransferSender`, `TransferReceiver` actors; `StagingArea`; `FolderDestinationStore`; outcome ledger; disk-space check; cleanup.
- **Dependencies:** Phase 2.
- **Acceptance:** T-05 (1/10/100 MiB checksums), T-06, T-07, T-09, traversal and oversize rejections, all over real TLS loopback.
- **Status:** VERIFIED (automated on one Mac). Cross-device transfer is verified in Phase 8.
- **Also delivered:** `BridgeServices`: `SenderService` (pairing, supervised session with reconnect/backoff/path changes, sending, history) and `ReceiverService` (availability, pairing approval, session auth, receiving, history), so the apps stay thin.
- **Test results:** `TransferTests` (12), `StorageTests` (4) and `ServiceEndToEndTests` (5: full flow, T-12 restart persistence, reconnection, Mac-side unpair revocation, T-02) all pass. T-05 over TLS loopback: 1 MiB 0.03 s, 10 MiB 0.07 s, 100 MiB 0.46 s (≈217 MiB/s), SHA-256 identical.
- **Risks:** Wi-Fi throughput is far below loopback; real numbers come from device acceptance.

## Phase 4: iOS experience
- **Objective:** onboarding, picker/gallery, gesture canvas, transfer UI, settings.
- **Dependencies:** Phases 2–3.
- **Acceptance:** all screens functional with real services; UI tests for onboarding, gallery, settings, error states.
- **Status:** IMPLEMENTED. UI tests 5/5 pass on the simulator; real gesture feel and Photos import await device acceptance.

## Phase 5: macOS experience
- **Objective:** menu bar utility, overlay, arrival animation, destination, notifications, login item.
- **Dependencies:** Phases 2–3.
- **Acceptance:** receives real transfers from the loopback sender; overlay never takes focus; success only after COMMITTED.
- **Status:** IMPLEMENTED. The receive path is verified through `ReceiverService` E2E tests and the menu bar UI test passes; overlay placement on full-screen and multi-display setups (T-10) awaits a manual run.

## Phase 6: Spatial coordination
- **Objective:** calibration on both sides, gesture → overlay mapping, provisional/final animation states, latency metrics.
- **Dependencies:** Phases 4–5.
- **Status:** IMPLEMENTED. The iPhone applies placement, alignment and mirroring. The Mac derives the arrival edge from the gesture edge and adds its display choice and nudge. The overlay starts on ACCEPT and turns to success only on COMMITTED. `overlayStartLatency` and `gestureToOfferLatency` metrics are recorded. Mapping is verified by `CoordinateMapperTests`.

## Phase 7: Hardening
- **Objective:** full test run, security review, memory check, failure matrix, accessibility.
- **Status:** IMPLEMENTED. 113 package tests, 6 UI tests and the analyzer all pass. Security review is in `docs/Testing/SECURITY_REVIEW.md`. A memory defect was fixed (308 MB → 103 MB peak). The automated failure matrix covers disconnect, corruption, disk full, revoked folder, untrusted peer and restart. Wi-Fi drop, sleep and backgrounding are in the device plan. Accessibility: VoiceOver labels and actions, Reduce Motion, Dynamic Type via system fonts, keyboard shortcuts on the Mac; a full VoiceOver pass on device is pending.

## Phase 8: Release preparation
- **Objective:** release configs, install/release docs, release notes, final verification report, physical-device acceptance.
- **Status:** IN_PROGRESS. Release builds succeed. Archive and notarize scripts, release instructions, notes, checklist and the test report are written. The app is installed on the iPhone. **Blocked on human steps:** running `Scripts/device-acceptance.md`, plus a Developer ID certificate and an App Store Connect record for distribution.

---

# Cross-platform: Android sender, Windows receiver (ADR-013)

Branch `feature/cross-platform`. Android sends like the iPhone and Windows receives like the Mac, which gives four pairs: iPhone or Android → Mac or Windows. The protocol is re-implemented natively in Kotlin (`Apps/SpatialBridge-Android`) and C# .NET 10 (`Apps/SpatialBridge-Windows`). Swift-generated golden vectors (`Conformance/vectors`) and a loopback interop matrix (`Scripts/interop.sh`) keep the three implementations in agreement (`docs/API/CONFORMANCE.md`). Session TLS stays TLS 1.2 0xCCAC, using BouncyCastle on the JVM and .NET.

Scope of the evidence below: every run happened on one macOS host on 2026-10-23, over loopback or on the Android emulator. **Nothing has run on Windows, and nothing has run on a physical Android phone.** CI hasn't run either, because the push was refused (HTTP 403), so the new CI jobs have never executed.

## Phase XP0: Contracts and skeletons
- **Objective:** fix the cross-platform contracts before any port starts.
- **Tasks:** ADR-013 (Android/Windows ports, role mirroring, BouncyCastle; deviation from BRD §6), ADR-014 (transcript binds HELLO wire bytes, canonical JSON), ADR-015 (content types, platform values, filenames); ADR-010 title fix; `docs/API/CONFORMANCE.md` (canonical JSON profile, vector format, shared CLI contract); `Conformance/schema`; Gradle skeleton (`:core :cli :app`) and the .NET 10 solution (Core, Cli, Platform.Windows, App, tests); `SenderFacade` (Kotlin) and `IReceiverFacade` (.NET) contracts.
- **Dependencies:** Phase 8 codebase.
- **Acceptance:** the skeletons build (`./gradlew help`, `dotnet build`); the existing Swift tests stay green.
- **Status:** VERIFIED
- **Test results:** the XP0 commit (09028f5) records no run. The acceptance is confirmed by the 2026-10-23 re-run in `TEST_REPORT.md`: all Gradle and .NET projects build and the 138 Swift package tests pass.
- **Risks:** a third implementation of one protocol; any protocol change must update the vectors first.

## Phase XP1: Protocol ports and app shells (six lanes)
- **Objective:** port the protocol to Kotlin and .NET, remove the Apple-side interop blockers, generate golden vectors, and build both new app shells against fakes.
- **Tasks:**
  - **A (Apple compat):** transcript hashes HELLO wire bytes (ADR-014); open `DevicePlatform` with `android`/`windows` (ADR-015); `TransferPolicy` also denies by filename extension; platform-neutral copy and icons; public `SessionAuthenticator.signedContext`; `SessionChannel.send` no longer closes on `CancellationError`.
  - **A, follow-up (a2f6517):** `NetworkParameters.validateNegotiatedTLS` cancels any TLS connection with E004 at `.ready` unless it negotiated TLS 1.2 + 0xCCAC (ADR-010 consequence).
  - **V (vectors + harness):** `sb-swift` test CLI (`Conformance/SwiftHarness`: tls-echo, pair-initiate/respond, serve, send with faults); `VectorExportTests` writing 9 vector files (431 cases at the time) with a CI check mode.
  - **K (Kotlin core + `sb-jvm`):** canonical JSON, framing, pairing (both roles), BouncyCastle TLS 1.2 PSK 0xCCAC client/server, session auth, `TransferSender`, test receiver, sanitizer, `UtiMap`, gesture engine port, `SenderService`.
  - **N (.NET core + `sb-dotnet`):** `SpatialBridge.Core` (net10.0) with canonical JSON, framing, BouncyCastle TLS server/client (no `status_request` echo), pairing, session auth, `TransferReceiver`, ledger, Windows-strict `TransferPolicy` with a UTI catalog generated from macOS, Swift-exact sanitizer with managed NFC, `WindowsSaveName`, `CoordinateMapper`, `ReceiverService`.
  - **AU (Android shell):** Compose screens (onboarding, discovery, pairing SAS sheet, gesture send, transfer status with success only on COMMITTED, calibration, settings, history, diagnostics), NSD discovery merged by `pid`, Keystore-wrapped secret store, manifest hardening.
  - **WU (Windows shell):** `Platform.Windows` (DNS-SD advertiser, DPAPI store, exclusive `MoveFileEx` commit with Mark-of-the-Web, monitors, firewall profile) and a code-only WinUI 3 tray app (settings, pairing approval, click-through arrival overlay, notifications, `--smoke-test` fake).
- **Dependencies:** XP0. K and N needed V's `tls-echo` first; the vectors gate their acceptance.
- **Acceptance:** Swift package tests, both Apple builds and lint green; all vectors pass in Kotlin and .NET; BouncyCastle ↔ Network.framework handshakes in both directions; Android `assembleDebug`, unit and emulator UI tests green; the Windows app builds on a Windows runner and passes a tray-launch smoke test.
- **Status:** VERIFIED (loopback) for lanes A, V, K and N; VERIFIED (emulator) for AU; IMPLEMENTED for WU, which has never run on Windows.
- **Test results:**
  - A + V: 131 package tests; iOS simulator and macOS builds succeed. The `sb-swift` loopback run covers TLS-PSK echo, pairing (matching SAS and PSK fingerprint), 1 MiB to COMMITTED, replay and all six fault codes.
  - TLS enforcement: `TLSCipherSuiteTests` 4/4 (`validation`, `negotiatesCCAC`, `serverRefusesDowngrade`, `clientRefusesDowngrade`); 134 package tests.
  - K: 374 Kotlin tests including all vectors; TLS with Network.framework in both directions; jvm→swift pair, 1 MiB send and fault matrix on loopback.
  - N: 547 .NET Core tests including all vectors; swift→dotnet pair, 1 MiB send and fault matrix; TLS both directions on loopback.
  - AU: 29 unit tests and 4 instrumented tests on the `Pixel_7_Pro` API 37 emulator.
  - WU: compiles on macOS with 0 warnings; 52 platform tests pass, 7 Windows-only tests skipped.
- **Risks:** the BouncyCastle server must not echo `status_request` or BoringSSL rejects it (fixed in N, see SECURITY_REVIEW). Network.framework still offers plain-PSK suites; the refusal happens after the handshake (L-17).

## Phase XP2: Integration (XP2a Android, XP2b Windows, XP2c interop + CI)
- **Objective:** wire both apps to their real cores and prove all four pairs interoperate.
- **Tasks:**
  - **XP2a:** `AppGraph` builds `SenderService` from the Keystore secret store, a file trusted-peer store and an `AppPeerLocator` (NSD plus the debug manual endpoint); core `UtiMap`, `FilenameSanitizer` and gesture engine replace the placeholders; the fake facade moves to `androidTest`; fix for a repeated identical failure never being shown.
  - **XP2b:** `Platform.Windows` uses Core's contracts; `WindowsFileCommitter` on `FileCommit.CommitWithCollisions` with `MoveFileEx`; TXT records from `AdvertisedDevice`; overlay placement via Core's `CoordinateMapper` with per-monitor DPI; the App builds `ReceiverService` with DPAPI secrets, a file trusted-peer store, DNS-SD and the Windows committer; staging is Hidden on Windows.
  - **XP2c:** `Conformance/interop/run_matrix.py` (standard library only) and `Scripts/interop.sh` drive `sb-swift`, `sb-jvm` and `sb-dotnet` over loopback; CI jobs `android`, `dotnet-core` (blocking format check), `windows` (App build with `-warnaserror`, tests, tray smoke test) and `interop`; the `packages` job fails on stale vectors; `lint.sh` rejects Kotlin/C# logging of filenames or secrets; build wrappers `Scripts/build-android.sh` and `Scripts/build-windows.ps1`.
- **Dependencies:** XP1 (AU + K for XP2a, WU + N for XP2b, all lanes for XP2c).
- **Acceptance:** an emulator test pairs with and sends to `sb-swift serve` and `sb-dotnet serve` via `10.0.2.2` with a matching hash; a Windows CI integration test commits into a temp folder, maps reserved names and sets MotW; every matrix scenario passes for all four pairs.
- **Status:** XP2a VERIFIED (emulator, against `sb-swift`); XP2b IMPLEMENTED (never run on Windows); XP2c matrix VERIFIED (loopback); CI jobs IMPLEMENTED (never run, push refused with 403).
- **Test results:**
  - XP2a: emulator E2E (Pixel 7 Pro, API 37) against `sb-swift serve` via `10.0.2.2`: SAS match, a 3 MiB send COMMITTED with matching sha256, an unsafe type and a 0-byte file rejected with E006. 374 core and 30 app unit tests and 4 instrumented UI tests pass; lint clean apart from the bctls warnings. The commit records no emulator run against `sb-dotnet serve`; Android → .NET is covered only by the jvm→dotnet loopback matrix.
  - XP2b: 547 Core and 67 Platform tests pass on macOS (8 Windows-only skipped); the App builds for x64 and ARM64 with 0 warnings. The loopback receiver integration test `WindowsCommitOverLoopbackWithMotwAndHiddenStaging` is `[WindowsFact]` and skipped on macOS.
  - XP2c: swift→swift, swift→dotnet, jvm→swift and jvm→dotnet pass every scenario; `--self --large` gave 102/102 at that commit.
- **Risks:** the plan's rate-limit, 25 s keepalive, peer-killed (E005), concurrent-offer and Unicode display-name scenarios aren't in the matrix; they are covered only by per-implementation unit tests and the `pairing.json` vectors (non-ASCII names).

## Phase XP3: Hardening (H1 fuzzing and filenames, H2 correctness, H3 Android release, perf, security)
- **Objective:** fuzz the parsers, fix interop edge cases, measure loopback throughput and memory, harden the Android release build, and extend the security review.
- **Tasks:**
  - **H1:** seeded fuzz tests (Kotlin JUnit, .NET xUnit; `SB_FUZZ_ITERATIONS`) for frame headers/decoder, chunk payloads, control-message JSON and the filename sanitizer. Fixes: out-of-range doubles (`1e309`) accepted in Kotlin/.NET; non-JSON number tokens and lone surrogates accepted in Kotlin; Swift `isSafe` accepting a `/` or `\` combined into a grapheme (fixed identically in Swift, Kotlin and .NET, plus non-idempotent trimming, re-exposed hidden names, non-NFC output and over-255-byte extensions; 15 new sanitizer vectors). `unpair` in all three CLIs, picked up live by `serve`; `sb-swift` and `sb-jvm` serve purge staging older than 24 h; matrix scenarios `after-unpair` and `staging-purge`.
  - **H2:** collision names trim the stem first so `stem N.ext` fits 255 bytes (long colliding names failed E011) in Swift, .NET and Kotlin, with new long-name vectors; the Mac `ReceiverService` reports pairing success only after the re-keyed session listener is ready; `ReceiverEvent.replayed` for ledger replays.
  - **H3:** Android Done closes the Pair overlay; Reset wipes identity, keys, trust, manual-endpoint memory, history and settings; the graph loads off the main thread; a transfer survives activity recreation; R8 release build. `Conformance/interop/perf.py` for 100 MiB loopback throughput and peak memory. `SECURITY_REVIEW.md` cross-platform section.
- **Dependencies:** XP2.
- **Acceptance:** fuzzers run clean after the fixes; 100 MiB loopback with bounded memory for all four pairs; stale staging removed at start; release build passes the emulator E2E; security review written with a status per item.
- **Status:** VERIFIED (loopback and emulator) for H1, H2 and the Android/perf parts of H3. Windows runtime items in the security review are IMPLEMENTED.
- **Test results:**
  - H2: 138 package tests, 555 .NET Core and 393 Kotlin core tests; iOS and macOS builds succeed; interop 64/64.
  - H3: R8 release APK 3.3 MB, BouncyCastle JSSE/JCA stripped, passes the emulator E2E against `sb-swift`; perf.py shows memory flat with file size (see `TEST_REPORT.md`, 2026-10-23, for the re-run numbers).
  - H1: matrix 108/108 with `--self` (100 MiB opt-in skipped).
  - Re-run on 2026-10-23 (TEST_REPORT): 138 Swift, 409 Kotlin core, 31 Android app unit tests, 583 .NET Core, 67 .NET Platform (8 skipped); interop 108 passed, 6 skipped.
- **Risks:** the plan named jazzer and SharpFuzz; seeded property fuzzing in the unit-test runners was used instead (no coverage guidance). The Kotlin and .NET ports have no test that a plain-PSK-only peer is refused (SECURITY_REVIEW residual risks).

## Phase XP4: Device acceptance and docs
- **Objective:** run the four-pair matrix on real devices and bring the tracking docs up to date.
- **Tasks:** extend `Scripts/device-acceptance.md` with the cross-platform matrix (done); update this plan, `REQUIREMENTS_TRACEABILITY.md`, `KNOWN_LIMITATIONS.md`, `TEST_REPORT.md`, `SECURITY_REVIEW.md` and `README.md` (done); run the matrix on an iPhone, an Android phone, a Mac and a Windows PC on one Wi-Fi network; get CI to run on a Windows runner; change README and `Website/` claims only for pairs that are `VERIFIED` in the test report.
- **Dependencies:** XP3; the user's Android phone and Windows PC; push access for CI.
- **Acceptance:** every cell of the cross-platform matrix in `Scripts/device-acceptance.md` recorded in `TEST_REPORT.md`; the Windows CI job green.
- **Status:** IN_PROGRESS. Docs updated. Physical-device acceptance: NOT_STARTED. Windows CI: NOT_STARTED (push refused with 403).
- **Test results:** none on devices or Windows yet.
- **Risks:** the Windows app has never launched on Windows, so first-run failures (WinUI packaging, DNS-SD, firewall prompt) are likely to show up during acceptance. Android NSD is unverified on a real network (L-22).
