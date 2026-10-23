# Requirements Traceability Matrix

Statuses: `NOT_STARTED`, `IN_PROGRESS`, `BLOCKED`, `IMPLEMENTED`, `VERIFIED`. **VERIFIED** means an automated test or an executed manual check passed (evidence in `TEST_REPORT.md`). Anything that needs two physical devices stays **IMPLEMENTED** until the Phase 8 device acceptance run (`Scripts/device-acceptance.md`) is executed.

Module paths are relative to `Packages/SpatialBridgeKit/Sources/` unless prefixed with `Apps/`.

## Business requirements (BRD §5)

| ID | Requirement | Implementation | Tests | Status |
|---|---|---|---|---|
| BR-01 | One-time user-approved pairing; unknown peers cannot transfer | `BridgeSecurity/PairingProtocol.swift`, `SessionAuthenticator.swift`, TLS-PSK (`BridgeNetworking/NetworkParameters.swift`), `TransferReceiver.validate` | `PairingProtocolTests`, `SessionAuthenticatorTests.untrusted`, `NetworkLoopbackTests.unknownIdentityRejected`, `TransferTests.spoofedSource` | VERIFIED (loopback); device run pending |
| BR-02 | Nearby local discovery | `BridgeNetworking/BonjourBrowser.swift`, `ServiceAdvertiser.swift` | `BonjourDiscoveryTests` (real Bonjour, 0.92 s) | VERIFIED (single host); cross-device pending |
| BR-03 | Spatial gesture, deterministic accept/reject with feedback | `BridgeGesture/*`, `Apps/…-iOS/Send/GestureCanvas.swift` | `SpatialGestureEngineTests` (synthetic traces) | VERIFIED (engine); device feel pending |
| BR-04 | Receiver animation mapped to calibrated edge | `BridgeCalibration/CoordinateMapper.swift`, `Apps/…-macOS/Overlay/ArrivalOverlay.swift` | `CoordinateMapperTests`; manual "Test Arrival" | IMPLEMENTED |
| BR-05 | Local save and notification; user can open the file | `TransferReceiver`, `BookmarkedFolderStore`, `Notifier`, history "Reveal in Finder" | `TransferTests.integrity`, `ServiceEndToEndTests.fullFlow` | VERIFIED (package); app path pending device run |
| BR-06 | No account or cloud | No backend; LAN only | Architecture review | VERIFIED |
| BR-07 | Privacy and explicit permissions | PhotosPicker (no library permission), user-selected folder bookmark, Local Network strings, privacy manifests | Code review; `PrivacyInfo.xcprivacy` | IMPLEMENTED |
| BR-08 | Multiple files and reverse transfer | Out of MVP scope (Could). Gallery multi-select is in; files send one at a time | n/a | NOT_STARTED (post-MVP, see KNOWN_LIMITATIONS) |

## iOS functional requirements (FRD §2)

| ID | Requirement | Implementation | Tests | Status |
|---|---|---|---|---|
| FR-101 | PhotosPicker, user-controlled access | `Apps/…-iOS/Send/HomeView.swift` (PhotosPicker), no photo-library usage key | UI test `testHomeShowsEmptyAndDisconnectedStates` | IMPLEMENTED |
| FR-102 | Async load into temporary file, bounded memory | `Gallery/GalleryModel.swift` (`FileRepresentation` → staging copy) | Manual on device | IMPLEMENTED |
| FR-103 | Record location, timestamp, velocity | `BridgeGesture/VelocityEstimator.swift`, `ThrowController` | `SpatialGestureEngineTests` | VERIFIED |
| FR-104 | Outward edge crossing + configurable speed and distance | `SpatialGestureEngine`, `GestureConfiguration`, Settings sensitivity | `SpatialGestureEngineTests` (T-03/T-04 traces) | VERIFIED |
| FR-105 | Metadata offer before bytes | `TransferSender.perform` | `TransferTests.diskFull` (rejected before streaming) | VERIFIED |
| FR-106 | Bounded chunks with progress | `ChunkedFileReader`, `SessionChannel` bounded inbox, acked progress | `TransferTests.integrity`, `NetworkLoopbackTests.chunkStream` | VERIFIED |
| FR-107 | Pairing code and peer identity shown, explicit approval | `Pairing/PairingViews.swift`, Mac `PairingApprovalView` | `PairingProtocolTests` | IMPLEMENTED (UI), VERIFIED (protocol) |
| FR-108 | One transfer per gesture | Engine latch (`hasFired`), `AppModel.send` guard, single transfer ID, ledger | `SpatialGestureEngineTests`, `TransferTests.replayIsIdempotent`, `retrySameID` | VERIFIED |
| FR-109 | Manual Send alternative | Send button + VoiceOver action "Send to Mac" | UI review | IMPLEMENTED |

## macOS functional requirements (FRD §3)

| ID | Requirement | Implementation | Tests | Status |
|---|---|---|---|---|
| FR-201 | Menu-bar accessory (LSUIElement) with accessible settings | `SpatialBridgeMacApp` (MenuBarExtra + Settings scene) | macOS UI test | IMPLEMENTED |
| FR-202 | Advertise only while Available | `ReceiverService.setAvailable`, `ServiceAdvertiser.stop` | `ServiceEndToEndTests.reconnects` | VERIFIED |
| FR-203 | Validate sender, type, size, disk before accepting | `TransferReceiver.validate`, `TransferPolicy` | `TransferTests` (oversize, deniedType, diskFull, spoofedSource, traversal) | VERIFIED |
| FR-204 | Transparent non-activating overlay at mapped coordinate | `OverlayPanel` (`.nonactivatingPanel`, `ignoresMouseEvents`, never key) | Manual | IMPLEMENTED |
| FR-205 | Primary display MVP, multi-display P1 | Display picker; fallback to main display (`CoordinateMapper.selectDisplay`) | `CoordinateMapperTests` | IMPLEMENTED |
| FR-206 | Stage, hash-verify, atomic move | `StagingArea`, `StagedFileWriter`, `FolderDestinationStore.commit` | `TransferTests.corruptedChunk`, `StorageTests` | VERIFIED |
| FR-207 | Security-scoped bookmark persisted; stale prompts again | `BookmarkedFolderStore` | `TransferTests.destinationRevoked` (package level) | IMPLEMENTED (app bookmark path needs a manual run) |
| FR-208 | Collision without overwrite | `renamex_np(RENAME_EXCL)` loop | `TransferTests.duplicateNames`, `StorageTests.exclusiveCommit` | VERIFIED |
| FR-209 | Success only after durable save | COMMITTED sent after commit; overlay `showSaved` only on `.committed` | `TransferTests.integrity` (state order) | VERIFIED |
| FR-210 | Notification fallback | `Notifier` when the overlay is disabled or unavailable | Manual | IMPLEMENTED |

## Test cases (FRD §8)

| ID | Description | Automated coverage | Device | Status |
|---|---|---|---|---|
| T-01 | Pair with matching code | `PairingProtocolTests.successfulPairing`, `NetworkLoopbackTests.pairThenSession` | pending | VERIFIED (loopback) |
| T-02 | Reject pairing → no transfer | `responderRejects`, `ServiceEndToEndTests.rejectedPairing` | pending | VERIFIED (loopback) |
| T-03 | Flick below threshold → no transfer | gesture traces | pending | VERIFIED (engine) |
| T-04 | Flick above threshold → one offer | gesture traces, FR-108 tests | pending | VERIFIED (engine) |
| T-05 | 1/10/100 MiB, SHA-256 matches | `TransferTests.integrity` over TLS loopback | pending | VERIFIED (loopback) |
| T-06 | Disconnect mid-stream → no file, retry | `disconnectMidStream` | pending | VERIFIED (fake link) |
| T-07 | Corrupt chunk → rejected | `corruptedChunk` | n/a | VERIFIED |
| T-08 | Revoke folder → re-prompt | `destinationRevoked` (E009) + app banner | pending | IMPLEMENTED |
| T-09 | Duplicate filename | `duplicateNames` | pending | VERIFIED |
| T-10 | Full screen / Spaces / dual monitors | Panel collection behaviour + notification fallback | pending | IMPLEMENTED |
| T-11 | Untrusted peer → denied | `unknownIdentityRejected`, `wrongKeyRejected`, `SessionAuthenticatorTests` | pending | VERIFIED (loopback) |
| T-12 | Restart → trust persists | `ServiceEndToEndTests.restartPersistence` | pending | VERIFIED (loopback) |

## Error codes (FRD §7)

All of E001–E014 are defined in `BridgeModels/BridgeError.swift` with a user message, a recovery suggestion and a retryability flag (`ControlMessageTests.errorCodes`). Where each one is produced:

| Code | Raised by |
|---|---|
| E001 | `NetworkErrorMapper` (DNS policy denied) → discovery/permission UI |
| E002 | No endpoint / connection refused; iOS shows troubleshooting |
| E003 | Pairing rejected or rate-limited |
| E004 | TLS PSK failure, bad signatures, untrusted peer |
| E005 | Connection closed, keepalive timeout |
| E006 | Unsafe name, unknown or denied type, empty file |
| E007 | Larger than `maxFileBytes` |
| E008 | Free space below size + headroom; ENOSPC |
| E009 | Missing, stale or unwritable destination bookmark |
| E010 | Size or digest mismatch |
| E011 | Rename/write errors |
| E012 | Version mismatch, malformed or oversized frames, out-of-order chunks |
| E013 | Sender or receiver cancel |
| E014 | Handshake or idle timeouts |

## Non-functional

| Area | Target | Evidence | Status |
|---|---|---|---|
| Encrypted, authenticated transport | TLS + mutual auth | ADR-010, loopback tests | VERIFIED |
| No main-thread file I/O | Hashing and reading off main | `FileHasher` (detached), actors | IMPLEMENTED |
| Bounded memory | Window × chunk | ADR-007; 100 MiB loopback transfer | VERIFIED (functional); Instruments profile pending |
| Privacy-safe logs | No filenames or secrets | `Redaction`, `Scrubber`, `DiagnosticsTests` | VERIFIED |
| Accessibility | VoiceOver, Dynamic Type, Reduce Motion, keyboard Mac controls | Labels/actions, `accessibilityReduceMotion`, keyboard shortcuts | IMPLEMENTED |
| Discovery < 5 s | | 0.92 s same host | VERIFIED (single host) |
| Throughput | | 100 MiB in 0.46 s on loopback | Loopback only |

## Cross-platform (ADR-013)

Android paths are relative to `Apps/SpatialBridge-Android/`, Windows paths to `Apps/SpatialBridge-Windows/src/` (tests: `Apps/SpatialBridge-Windows/tests/`). "Loopback" means one macOS host on 2026-10-23, and "emulator" means the `Pixel_7_Pro` API 37 emulator (evidence in `TEST_REPORT.md`, 2026-10-23). Nothing has run on Windows or on a physical Android phone, and the new CI jobs have never run (push refused with 403).

| ID | Requirement | Implementation | Tests | Status |
|---|---|---|---|---|
| XP-01 | Android sender parity with the iPhone (discover, pair with SAS, gesture send, success only on COMMITTED, history, settings, reset) | `core/…/service/SenderService.kt`, `session/PairingProtocol.kt`, `transfer/TransferSender.kt`, `gesture/SpatialGestureEngine.kt`; `app/…/AppGraph.kt`, `AppModel.kt`, `platform/NsdPeerDiscovery.kt`, `platform/KeystoreSecretStore.kt`, `ui/*` | `LoopbackTest`, `SpatialGestureEngineTest` (`traces.json`), `AppModelTest.successOnlyAfterCommitted`, `TransferUiMapperTest.successOnlyOnCommitted`, `TxtRecordsTest`; instrumented `SenderFlowTest`, `EmulatorE2ETest.pairSendCommitThenFailurePaths`, `ResetTest`, `RecreationTest`; interop jvm→swift, jvm→dotnet | VERIFIED (loopback + emulator); real-network NSD and device feel pending |
| XP-02 | Windows receiver parity with the Mac (advertise, pairing approval, stage/verify/commit, collisions, notifications, overlay) | `SpatialBridge.Core/Services/ReceiverService.cs`, `Transfer/TransferReceiver.cs`, `Transfer/Staging.cs`; `SpatialBridge.Platform.Windows/Discovery/DnsSdServiceAdvertiser.cs`, `Storage/WindowsFileCommitter.cs`, `Security/DpapiSecretStore.cs`; `SpatialBridge.App/*` (tray, `PairingApprovalWindow`, `Overlay/LayeredOverlayWindow.cs`) | `ReceiverLoopbackTests` (`PairTlsAuthTransferCommit`, `ReplayReturnsCommittedWithoutSecondFile`, `FaultsFailCleanly`, `SecondOfferDuringTransferIsBusy`, `RateLimitLocksAfterThreeFailures`), `ReceiverIntegrationTests.PortableCommitOverLoopback`; interop swift→dotnet, jvm→dotnet. `WindowsCommitOverLoopbackWithMotwAndHiddenStaging` and the App smoke test are Windows-only and have not run | VERIFIED (Core, loopback on macOS); IMPLEMENTED (Windows runtime and app) |
| XP-03 | Pairing transcript hashes the HELLO wire bytes (ADR-014) | `BridgeSecurity/PairingCrypto.swift`, `PairingProtocol.swift`, `BridgeCore/SessionChannel.swift`; Android `core/…/crypto/Crypto.kt`, `session/PairingProtocol.kt`; Windows `SpatialBridge.Core/Crypto/Crypto.cs` (`PairingTranscript`), `Pairing/PairingProtocol.cs` | `PairingCryptoTests.wireBytesMatchLegacyHash`, `wireBytesKeepUnknownKeys`; `pairing.json` vectors in `CryptoVectorTest` and `PairingVectorTests`; interop `pair-approve` (SAS and PSK fingerprint equal) on all pairs | VERIFIED (loopback) |
| XP-04 | Open platform values: `android`, `windows` and unknown values decode and round-trip (ADR-015) | `BridgeModels/Peer.swift` (`DevicePlatform`), neutral copy in `BridgeError.swift`; `core/…/model/Models.kt`; `SpatialBridge.Core/Messages/ControlMessages.cs` | `ControlMessageTests.helloRoundTrip` (iOS, macOS, android, windows, beos), `knownValues`, `neutralCopy`; `TxtRecordsTest.keepsUnknownPlatformsAndDropsEmpty`; `control-messages.json` vectors | VERIFIED |
| XP-05 | Receivers also deny by the offered filename's extension (ADR-015) | `BridgeTransfer/FilenameSanitizer.swift` (`TransferPolicy`, `UTType(filenameExtension:)`); `SpatialBridge.Core/Transfer/TransferPolicy.cs` (Windows denylist, also checked on the save name) | `FilenameAndHashingTests.deniedByExtension` (`x.sh` as `public.data` → E006); `TransferPolicyTests.DeniesWindowsExecutablesAsData`, `UtiPolicyVectorTests.AtLeastAsStrictAsMac`, `ReceiverLoopbackTests.DeniedTypeAndExtension`; `uti-policy.json`; interop `denied-type` | VERIFIED (loopback) |
| XP-06 | Windows save names (reserved names, illegal characters, trailing dots/spaces) and Mark-of-the-Web | `SpatialBridge.Core/Transfer/FilenameSanitizer.cs` (`WindowsSaveName`), `Transfer/Staging.cs` (`FileCommit`); `SpatialBridge.Platform.Windows/Storage/MarkOfTheWeb.cs`, `WindowsFileCommitter.cs` | `WindowsSaveNameTests` (`Maps`, `TrailingDotCannotSmuggleDeniedExtension`, `LongNamesKeepTheCollisionCounter`), `CollisionNameTests.ReservedNamesAreMappedForEveryCandidate`, `ReceiverLoopbackTests.CollisionsAndReservedNames`, `MarkOfTheWebTests.ContentIsInternetZone` (macOS). `MarkOfTheWebTests.AppliesOnNtfs` and `WindowsFileCommitterTests.CommitsExclusivelyWithCollisionRenameAndMotw` are `[WindowsFact]`, skipped | VERIFIED (name logic); IMPLEMENTED (NTFS commit and MotW) |
| XP-07 | Session TLS limited to TLS 1.2 0xCCAC on every implementation | `BridgeNetworking/NetworkParameters.swift` (`validateNegotiatedTLS`), `NWFrameTransport.open`; Android `core/…/net/PskTls.kt`; Windows `SpatialBridge.Core/Tls/PskTls.cs` | `TLSCipherSuiteTests` (`validation`, `negotiatesCCAC`, `serverRefusesDowngrade`, `clientRefusesDowngrade`); `PskTlsTest`; `TlsLoopbackTests`; `sb-jvm tls-echo --cipher-suite` probe | VERIFIED (Swift enforcement, loopback); Kotlin/.NET suite pinning by configuration (no downgrade test) |
| XP-08 | Cross-implementation interop matrix (all four pairs) | `Conformance/interop/run_matrix.py`, `scenarios.json`, `Scripts/interop.sh`; CLIs `Conformance/SwiftHarness` (`sb-swift`), Android `cli/` (`sb-jvm`), Windows `SpatialBridge.Cli` (`sb-dotnet`); CI job `interop` | `Scripts/interop.sh --self`: 108 passed, 6 skipped (100 MiB opt-in); `--self --large`: 114/114 | VERIFIED (loopback); CI never run |
| XP-09 | Swift-generated golden vectors pass in all three implementations | `Packages/SpatialBridgeKit/Tests/Conformance/VectorExportTests/*`, `Conformance/vectors/*.json` (9 files), `Conformance/schema/` | `VectorExportTests` (check mode); Kotlin `CodecVectorTest`, `CryptoVectorTest`, `TransferVectorTest`; .NET `VectorTests.cs` (`FramingVectorTests` … `CoordinateMapperVectorTests`) | VERIFIED |
| XP-10 | Parser and sanitizer fuzzing | Android `core/src/test/…/fuzz/*`; Windows `tests/SpatialBridge.Core.Tests/Fuzz/*` (`SB_FUZZ_ITERATIONS`) | `FrameFuzzTest`, `ControlMessageFuzzTest`, `SanitizerFuzzTest`; `FrameFuzzTests`, `ControlMessageFuzzTests`, `SanitizerFuzzTests`; fixes covered by `sanitizer.json` (15 new vectors) | VERIFIED (seeded property fuzzing, default iterations; no coverage-guided fuzzer) |
| XP-11 | Unpair revokes a peer's sessions, including in a running receiver | `BridgeServices/ReceiverService.swift` (`unpair`); `SpatialBridge.Core/Services/ReceiverService.cs` (`UnpairAsync`); CLIs: `sb-swift Unpair.swift`, Android `cli/…/Commands.kt`, `SpatialBridge.Cli/Commands.cs` | `ServiceEndToEndTests` (Mac-side unpair revocation), `ReceiverLoopbackTests.UnpairRevokesSessions`; interop `after-unpair` (E004 both sides, all pairs) | VERIFIED (loopback); app unpair on Android/Windows devices pending |
| XP-12 | Stale staging (`.sbpart` older than 24 h) purged at receiver start | `BridgeTransfer/Storage.swift` (`StagingArea.purge`), `BridgeServices/ReceiverService.swift` (start); `SpatialBridge.Core/Transfer/Staging.cs` (`StagingArea`), `ReceiverService.PurgeStaging`; `sb-swift Serve.swift`, `sb-jvm Commands.kt` (`purgeStaging`) | `TransferTests.purge` (function level); interop `staging-purge` (all pairs); `Conformance/interop/perf.py` (swift and dotnet serve: stale removed, fresh kept). No .NET unit test for `Purge`, and no test that the Mac `start()` triggers it | VERIFIED (CLIs, loopback); IMPLEMENTED (app start path) |
