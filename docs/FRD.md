# Functional Requirements Document — Spatial Bridge
Version 1.0 | Normative requirements and test cases

## 1. State machines
### Peer
idle → permissionPending → discovering → pairing → authenticating → connected → reconnecting → disconnected. Failure/denial branches return to discoverable states with explicit errors.
### Transfer
created → offered → accepted → streaming → verifying → committed → completed. Any stage may become failed/canceled; partial temporary files are cleaned after a bounded retention period.

## 2. iOS requirements
| ID | Functional requirement | Acceptance |
|---|---|---|
| FR-101 | Select images through PhotosPicker with user-controlled access | No full library permission required for picker-only workflow |
| FR-102 | Load selected transferable representation asynchronously into a temporary file | Memory remains bounded for large images |
| FR-103 | Record gesture location, timestamp and predicted/end translation | Derived velocity is stable and testable |
| FR-104 | Trigger on outward edge crossing plus configurable speed and distance | Accidental drags do not send |
| FR-105 | Send metadata offer before bytes | Receiver can reject for policy/storage |
| FR-106 | Stream bytes in bounded chunks and display progress | UI remains responsive |
| FR-107 | Show pairing confirmation code and peer identity | User explicitly approves |
| FR-108 | Prevent duplicate send from a single gesture | One transfer ID per activation |
| FR-109 | Provide manual Send alternative | VoiceOver and reduced-motion users can send |

## 3. macOS requirements
| ID | Functional requirement | Acceptance |
|---|---|---|
| FR-201 | Run as menu-bar accessory app with LSUIElement where appropriate | Settings/onboarding remain accessible |
| FR-202 | Advertise discoverable service only while user enables availability | Discovery can be disabled |
| FR-203 | Validate paired sender, file type, size and disk capacity before accepting | Untrusted/oversize rejected |
| FR-204 | Render transparent non-activating NSPanel/NSWindow overlay at mapped coordinate | Focus stays in active app |
| FR-205 | Support primary-display MVP; multi-display in P1 | Deterministic fallback |
| FR-206 | Stage bytes in application temporary folder, hash-verify, then atomically move | No corrupt final file |
| FR-207 | Save into user-approved folder using persisted security-scoped bookmark | Restart retains valid access; stale bookmark prompts again |
| FR-208 | Resolve filename collision without overwrite | Both files remain available |
| FR-209 | Acknowledge durable completion only after successful save | Sender shows success accurately |
| FR-210 | Provide notification fallback when overlay is unavailable | User still sees result |

## 4. Network protocol
Use length-prefixed, versioned control messages (JSON or CBOR) over authenticated reliable stream. Binary file data travels separately in framed chunks, not encoded into JSON.

| Message | Fields |
|---|---|
| HELLO | protocolVersion, peerID, capabilities, sessionNonce |
| PAIR_REQUEST | ephemeralPublicKey, displayName, challenge |
| PAIR_CONFIRM | challengeResponse, approvedPeerKeyID |
| TRANSFER_OFFER | transferID, safeName, MIME/UTType, byteCount, SHA256, exitEdge, normalizedPosition, velocity |
| TRANSFER_ACCEPT/REJECT | transferID, decision, reason |
| CHUNK | transferID, sequence, offset, byteCount, binary bytes |
| PROGRESS/ACK | transferID, acknowledgedOffset |
| COMPLETE | transferID, SHA256, byteCount |
| COMMITTED/ERROR/CANCEL | transferID, status/errorCode |

Protocol invariants: max control frame 64 KiB; bounded chunks proposed 256 KiB; max MVP file 100 MiB; verify exact byte count and SHA-256; sanitize names; reject path separators and traversal; limit simultaneous transfers to one in MVP; IDs are UUIDs; monotonically increasing offsets; replay detection and timeouts. These numbers are configuration defaults, not OS guarantees.

## 5. Security and trust
Pair using authenticated key exchange and an out-of-band short authentication string approved on both screens. Persist trusted device public key/key identifier in Keychain; encrypt and authenticate every session (e.g., TLS with pinned peer identity or correctly implemented Noise-based handshake). Never rely on Bonjour name, IP address, or BLE RSSI as authentication. Avoid writing custom cryptographic primitives.

## 6. Coordinate mapping
Represent exit edge as enum(top,bottom,left,right), position normalized to [0,1] along the edge, and velocity points/second. Calibration maps iPhone edge to configured Mac arrival edge. For Mac window placement convert normalized position into NSScreen.visibleFrame coordinates, handling differing coordinate origins and display scale. Clamp overlay bounds.

## 7. Errors
E001 local network denied; E002 no peer; E003 pairing rejected; E004 authentication failed; E005 peer lost; E006 unsupported file; E007 size limit; E008 insufficient storage; E009 destination permission expired; E010 hash mismatch; E011 write failed; E012 protocol mismatch; E013 transfer canceled; E014 timeout. All have actionable user messages.

## 8. Test cases
| ID | Steps | Expected |
|---|---|---|
| T-01 | Pair two devices with matching code | Trusted link established |
| T-02 | Reject pairing | No transfer possible |
| T-03 | Flick below threshold | No transfer |
| T-04 | Flick above threshold | One offer sent |
| T-05 | Transfer 1/10/100 MiB files | Correct SHA-256 and destination |
| T-06 | Disconnect during stream | No final file, explicit retry |
| T-07 | Corrupt chunk/test hash mismatch | Transfer rejected |
| T-08 | Revoke folder permission | Prompt for new destination |
| T-09 | Duplicate filename | Collision-safe filename |
| T-10 | macOS full screen, Spaces, dual monitors | Overlay or documented fallback |
| T-11 | Untrusted peer attempts send | Denied |
| T-12 | Restart both apps | Trust persists; transfer works |

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
