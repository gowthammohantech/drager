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
