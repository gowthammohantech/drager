# Implementation Plan

Statuses: `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `IMPLEMENTED`, `VERIFIED`. `VERIFIED` means the acceptance criteria were executed successfully. See `TEST_REPORT.md` for evidence.

Architecture summary: two native apps over a shared platform-neutral SwiftPM package (`Packages/SpatialBridgeKit`). The iPhone browses Bonjour, pairs with a SAS-verified X25519 handshake, and then opens TLS 1.3 PSK sessions to the Mac. Files stream as bounded binary chunks after a metadata offer. The Mac stages, verifies, atomically commits, and only then confirms (ADR-001…012).

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
- **Status:** NOT_STARTED

## Phase 5: macOS experience
- **Objective:** menu bar utility, overlay, arrival animation, destination, notifications, login item.
- **Dependencies:** Phases 2–3.
- **Acceptance:** receives real transfers from the loopback sender; overlay never takes focus; success only after COMMITTED.
- **Status:** NOT_STARTED

## Phase 6: Spatial coordination
- **Objective:** calibration on both sides, gesture → overlay mapping, provisional/final animation states, latency metrics.
- **Dependencies:** Phases 4–5.
- **Status:** NOT_STARTED

## Phase 7: Hardening
- **Objective:** full test run, security review, memory check, failure matrix, accessibility.
- **Status:** NOT_STARTED

## Phase 8: Release preparation
- **Objective:** release configs, install/release docs, release notes, final verification report, physical-device acceptance.
- **Status:** NOT_STARTED
