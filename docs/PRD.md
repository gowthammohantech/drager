# Product Requirements Document — Spatial Bridge
Version 1.0 | Platforms: iOS + macOS

## 1. Product promise
Select a photo on iPhone, flick it toward a chosen edge, and watch a visual arrival on Mac. Files remain on the local network and land in the user's approved destination folder.

## 2. Core user journey
1. Install/open both apps.
2. Mac menu-bar onboarding asks for local network and user-selected destination folder; user may choose Desktop.
3. iPhone requests local-network access when discovery starts and photo selection access only when invoked.
4. Discover nearby Mac via Bonjour; show recognizable peer name and pairing confirmation code on both screens.
5. User confirms code and chooses relative layout (phone below/left/right/above Mac) and Mac display.
6. User picks photo through PhotosPicker, previews it, then flicks toward calibrated edge.
7. iPhone shows sending state; Mac shows arrival preview followed by saved confirmation.
8. On failure, show actionable retry without duplicating the saved file.

## 3. Screens and navigation
### iOS
Welcome → Permission explainer → Discover peers → Verify pairing → Calibration → Asset picker/grid → Preview/gesture canvas → Transfer status → History/settings.
### macOS
Menu-bar status → Onboarding/pairing sheet → Destination picker → Calibration overlay → Receiving animation → Completion toast → Recent transfers/preferences.

## 4. Functional feature specifications
| Feature | Behavior | Edge case |
|---|---|---|
| Discovery | Show available compatible peers and connection state | Router blocks mDNS: troubleshooting and retry |
| Pairing | Explicitly approve matching short code; remember trusted public key | Unknown device must not auto-accept |
| Calibration | Choose physical relative direction, display and normalized edge coordinate | Display changed: recalibrate |
| Gesture | Start drag on selected asset; arm near configured edge; trigger on threshold and outward velocity | Accidental edge scrolling must not send |
| Transfer | Stream original or selected representation; show progress | Low storage, dropped link, canceled session |
| Overlay | Show small click-through visual without stealing focus | Full-screen app: fallback to notification |
| Save | Atomic move from temporary staging to approved directory | Filename collision: append safe suffix |
| History | Local metadata, result and open-in-Finder action | User can clear history |

## 5. Gesture UX contract
- Gesture tracking is restricted to the app's preview/canvas; do not claim system-wide gestures.
- Proposed thresholds: enter 24-point edge zone; release with outward velocity > 500 points/second; minimum travel 60 points; tune through device testing.
- Require a selected asset and paired connected peer; display armed-edge affordance and haptic on successful trigger.
- Normalized position along the exit edge is transmitted in [0,1]; speed controls animation intensity, not file transport priority.
- Support explicit Send button as accessible fallback.

## 6. Nonfunctional product requirements
| Attribute | Target |
|---|---|
| Privacy | No account; no upload to third-party servers |
| Accessibility | VoiceOver labels, reduced motion, high contrast, keyboard accessible Mac controls |
| Responsiveness | No blocking main thread for file reads or transfer |
| Security | User-confirmed trust and encrypted authenticated session |
| Recovery | Clear retry state; do not silently claim completion |
| Compatibility | Physical-device test matrix; simulator not sufficient for local peer discovery |

## 7. Analytics without sensitive content
Opt-in local-first events: pairing_started/succeeded, gesture_armed/triggered, transfer_started/completed/failed, animation_rendered; capture duration, byte-size bucket and error code, never photo bytes, filename or exact network identity.

## 8. Acceptance scenarios
- First run: permission declined → clear instructions to re-enable access.
- Peer discovery: only trusted/approved Mac receives a file.
- 10 MB JPEG transfer: original bytes preserved; checksum matches.
- Disconnect at 50%: partial file never appears as completed.
- Two transfers with same name: neither overwrites existing file.
- Multiple displays: correct configured display used.
- Reduced Motion: static non-distracting receipt instead of trajectory animation.
- No internet but working local Wi-Fi: transfer succeeds.

## 9. Prioritized backlog
P0: picker, discovery, pairing, streaming, gesture, single-display overlay, folder selection, errors. P1: history, multi-display, reconnect, accessibility, diagnostics. P2: batch transfer, reverse Mac→iPhone, richer effects, sharing extension subject to platform limitations.

## 10. UX design tokens (initial)
Dark translucent receiver card, 12–16 pt corner radius, 180–300 ms arrival animation, 44 pt minimum touch targets, system typography, clear success/error symbols. Follow system Reduce Motion setting.

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
