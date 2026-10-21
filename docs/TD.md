# Technical Design — Spatial Bridge
Version 1.0 | Swift / SwiftUI / AppKit / Network.framework

## 1. Supported targets
Select minimum supported iOS and macOS versions after validating actual test hardware and current Xcode SDK. Swift 5.9+ language compatibility is a baseline, not a promise that all current Network APIs exist on older OS releases. Xcode on macOS is required to build/sign both native targets.

## 2. Monorepo
```text
SpatialBridge/
├── Apps/
│   ├── SpatialBridge-iOS/       # Xcode app target, SwiftUI, PhotosPicker
│   └── SpatialBridge-macOS/     # menu-bar app, AppKit overlay, folder access
├── Packages/
│   ├── BridgeModels/            # protocol DTOs, transfer state, vectors
│   ├── BridgeNetworking/        # discovery, authenticated session, framing
│   ├── BridgeTransfer/          # chunking, hashing, validation, retry
│   ├── BridgeSecurity/          # identity, pairing, Keychain interfaces
│   ├── BridgeDiagnostics/       # redacted structured logs and metrics
│   └── BridgeTestSupport/       # fake transport, fixtures, clocks
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   └── E2E/
├── Config/                    # entitlements, Info.plist, xcconfig
├── Scripts/                   # build, lint, test, notarization helpers
├── Docs/                      # BRD PRD FRD TD AD ADRs
└── SpatialBridge.xcworkspace
```
Use Swift Package Manager for packages and an Xcode workspace/project for app targets. Tuist is optional if project generation complexity justifies it.

## 3. Core models
```swift
import Foundation

enum Edge: String, Codable, Sendable { case top, bottom, left, right }
struct ExitGesture: Codable, Sendable {
    let edge: Edge
    let normalizedPosition: Double  // 0...1
    let outwardVelocity: Double      // points/second
}
struct TransferOffer: Codable, Sendable {
    let protocolVersion: Int
    let transferID: UUID
    let filename: String
    let contentType: String
    let byteCount: Int64
    let sha256Hex: String
    let gesture: ExitGesture
}
enum TransferState: String, Codable, Sendable {
    case created, offered, accepted, streaming, verifying, committed, completed, failed, canceled
}
```
Never include the entire file bytes in TransferOffer. Define separate binary chunk framing.

## 4. Dependency contracts
```swift
protocol PeerDiscovery: Sendable {
    func start() async throws
    func stop() async
}
protocol SecurePeerSession: Sendable {
    func sendControl(_ data: Data) async throws
    func sendChunk(_ data: Data, transferID: UUID, offset: Int64) async throws
}
protocol DestinationStore: Sendable {
    func commit(stagedFile: URL, suggestedName: String) async throws -> URL
}
```
Use actors for connection lifecycle, transfer coordination and write serialization. UI updates must occur on MainActor. Implement protocol adapters per platform.

## 5. Networking implementation plan
- Advertise `_spatialbridge._tcp` using NWListener service registration and discover using NWBrowser with Bonjour. Confirm current API signatures in target SDK.
- Declare `NSLocalNetworkUsageDescription` and `NSBonjourServices` including `_spatialbridge._tcp` in both app targets where required.
- Connect via NWConnection with authenticated transport, keepalive, exponential reconnect backoff and cancellation.
- Bonjour discovery alone does not guarantee a peer-to-peer path across arbitrary networks; baseline is shared reachable LAN. Test Apple peer-to-peer options separately.
- No need to build raw UDP for MVP. Avoid duplicate MPC plus custom TCP stacks.

## 6. Pairing and authentication
Create long-term device identity in Keychain. During first pairing exchange ephemeral keys and display a short verification code derived from the authenticated transcript; both users approve. Persist peer public key and display name, allow revocation in Settings. Implement TLS identity validation with a tested strategy and security review; do not use permissive trust callbacks in production.

## 7. Photos and files
Use PhotosPicker and Transferable to obtain authorized asset representation; prefer loadTransferable file representation for bounded memory and copy temporary URLs into owned staging before picker scope ends. Account for iCloud-backed asset loading and limited network access. Compute streaming SHA-256 with CryptoKit, not one giant Data allocation.

## 8. macOS overlay
Create borderless transparent NSPanel or NSWindow: opaque=false, backgroundColor=.clear, ignoresMouseEvents=true, appropriate window level, nonactivating behavior and suitable collectionBehavior. Render via CoreAnimation/SwiftUI-hosted layer. Verify behavior in full-screen, Stage Manager and multi-display; provide UserNotifications fallback. `LSUIElement` hides normal Dock presence but should not make preferences inaccessible.

## 9. File destination
Present NSOpenPanel configured for directories. Save security-scoped bookmark and resolve it on restart; call startAccessingSecurityScopedResource when needed, balance stopAccessingSecurityScopedResource. Write staging file, verify checksum, then safely move to destination with collision handling. Consider macOS permissions and disk-full cases.

## 10. Build, CI/CD and distribution
- `swift test` for SPM packages on macOS runner; `xcodebuild test` for iOS simulator UI/unit tests and macOS targets.
- Physical-device E2E testing required for Bonjour, network permissions, pairing and gesture performance.
- Enforce SwiftFormat/SwiftLint where compatible, compiler warnings, concurrency checks, secret scanning, dependency review and release signing.
- iOS TestFlight distribution; macOS signed/notarized direct distribution or Mac App Store, depending on chosen sandbox strategy.
- Never store signing certificates or provisioning credentials in repo; use CI secrets.

## 11. Observability
OSLog with redacted peer identifiers, no file content, no filename in analytics. Measure discovery duration, pairing completion, first-byte latency, bytes/second, verify/save duration, animation start and failure reason. Local exportable diagnostic bundle must scrub personal data.

## 12. Delivery sequence (illustrative 8-week pilot)
Week 1: spike discovery, signing, privacy prompts. Week 2: identity and pairing. Weeks 3–4: streaming and verified save. Week 5: gesture and overlay. Week 6: calibration, errors, accessibility. Week 7: device/network/security test matrix. Week 8: beta hardening and KPI measurement. Timeline assumes available iOS and macOS engineers and is not a commitment.

## Research and platform constraints (20 October 2026)
- Apple marks MultipeerConnectivity deprecated; use Network.framework with Bonjour service discovery for the primary implementation. Legacy MPC can be a separately tested fallback, not a mandatory dependency.
- Bonjour browsing and advertising require local-network privacy authorization and declared service types in Info.plist. Test actual behavior on both supported OS versions.
- BLE RSSI is not proof of proximity, direction, or device ownership. The MVP uses user-confirmed pairing and manual spatial calibration; BLE is optional discovery assistance only.
- The iOS gesture works inside this application's UI only; no global Photos-app interception or system-wide drag-off-screen hooks.
- A macOS sandboxed app should ask the user to choose its destination folder and persist a security-scoped bookmark; Desktop is a suggested selection, not an unconditional writable path.
- File metadata/control messages must be separated from binary streaming. No large Data fields in Codable JSON.

### Research references
1. Apple Multipeer Connectivity deprecation: https://developer.apple.com/documentation/multipeerconnectivity
2. Apple local network privacy TN3179: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
3. Apple sandbox file access: https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
4. Apple NSOpenPanel: https://developer.apple.com/documentation/appkit/nsopenpanel
5. Apple NSWindow full-screen auxiliary: https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary

> Targets, performance thresholds and schedules below are proposed acceptance targets, not measured claims. Validate APIs, entitlements, signing, and deployment against the Xcode SDK used for release.
