# Business Requirements Document — Spatial Bridge
Version 1.0 | Status: Proposed | Product: iOS ↔ macOS spatial file transfer

## 1. Executive summary
Build companion iPhone and Mac apps enabling a user to select a photo/file, flick it toward a calibrated screen edge, and see a synchronized arrival animation on their Mac while the file is transferred locally. The product is an intentional visual alternative to traditional share sheets, not an OS-level replacement for AirDrop.

## 2. Problem and opportunity
Conventional transfer methods require destination selection, context switching, or a cloud workflow. The differentiator is a predictable, delightful interaction that is still transparent about pairing, permission, transfer progress, and failures.

## 3. Goals and measurable outcomes
| Goal | Proposed KPI | Validation |
|---|---|---|
| Fast repeat transfer | Median gesture-to-receiver acknowledgment < 500 ms on healthy LAN | Instrumented trials |
| Useful end-to-end performance | 10 MB photo completed in < 5 s on reference Wi-Fi | Device matrix benchmark |
| Setup ease | >= 90% of test users complete pairing in < 2 minutes | Moderated usability |
| Reliability | >= 99% successful completion on stable LAN for files <= 100 MB | 1,000-run test |
| Reuse | Shared protocol and network implementation across both targets | Package review |
| Delivery productivity | Measure development effort vs separate codebases; 30% reduction is a hypothesis | Sprint metrics |

## 4. Personas and jobs to be done
- Creator: move a camera image into an editing workstation quickly.
- Designer: hand off references while maintaining attention on the Mac.
- Presenter: move an asset from a phone to a Mac without cloud dependencies.

## 5. Business requirements
| ID | Requirement | Priority | Acceptance |
|---|---|---|---|
| BR-01 | One-time user-approved pairing | Must | Unknown peers cannot transfer |
| BR-02 | Nearby local discovery | Must | Discover available companion on permitted LAN |
| BR-03 | Spatial gesture with visible feedback | Must | Gesture accepted/rejected deterministically |
| BR-04 | Receiver animation | Must | Animation mapped to calibrated edge |
| BR-05 | Local file save and notification | Must | User can open resulting file |
| BR-06 | No required account or cloud | Must | Works without internet on compatible LAN |
| BR-07 | Privacy and explicit permissions | Must | No silent photo-library or Desktop access |
| BR-08 | Multiple files and reverse transfer | Could | Post-MVP roadmap |

## 6. Scope
### MVP in scope
Native iOS picker/gallery experience; macOS menu-bar companion; discovery, secure pairing, transfer, animated overlay, calibration, save-folder selection, retries, progress, error handling, transfer history (metadata only).
### Out of scope
System-wide iOS Photos gesture interception; Finder drag interception; Android/Windows; WAN relay; automatic physical-location inference; cloud backup; background iOS continuous advertising guarantees.

## 7. Commercial and operational assumptions
Initially free internal/TestFlight pilot; distribution decision (Mac App Store vs signed direct download) remains open. No server operating cost for file transit; Apple developer account, QA devices, signing, telemetry and support still have costs. Avoid a claim of zero infrastructure cost if analytics/crash reporting is enabled.

## 8. Risks and mitigations
| Risk | Impact | Mitigation |
|---|---|---|
| Network.framework peer-to-peer transport differs by hardware/network | High | Test Wi-Fi LAN baseline, assess peer-to-peer capability separately |
| iOS background suspension | High | Require foreground gesture and communicate availability clearly |
| Full-screen/Spaces overlay behavior | Medium | Explicit display/Spaces matrix and non-intrusive fallback notification |
| macOS Desktop access denial | High | User-selected save directory and bookmark renewal |
| Spoofed peers or replay | High | Authenticated pairing, trusted-peer registry, transfer nonce |
| Large files and memory pressure | High | Streaming, bounded buffers, disk staging |

## 9. Dependencies and decisions
Decide minimum iOS/macOS versions after device-market assessment; whether Mac App Store sandboxing is mandatory; max MVP file size (proposed 100 MB); whether iCloud-backed assets may download on demand; destination default; retention of local transfer history; privacy policy and crash reporting opt-in.

## 10. Release gates
G0 proof of network and overlay; G1 pairing/security review; G2 alpha acceptance; G3 accessibility and failure testing; G4 TestFlight + signed macOS beta; G5 measured KPI review.

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
