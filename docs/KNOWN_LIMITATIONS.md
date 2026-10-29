# Known Limitations

| # | Limitation | Impact | Mitigation / plan |
|---|---|---|---|
| L-01 | iOS gesture works only inside the Drager app | No system-wide Photos/Finder drag-off | Platform restriction (BRD out of scope) |
| L-02 | iOS sending requires the app in the foreground | Long transfers can fail if the app is backgrounded | Automatic retry (same transfer ID) on return; messaging |
| L-03 | Maximum file size 100 MiB in MVP | Larger files rejected with E007 | `TransferLimits.maxFileBytes` / `AppSettings.maxFileBytes` |
| L-04 | No resume; interrupted transfers restart (ADR-011) | Large transfers on flaky Wi-Fi restart from zero | Protocol already carries offsets and acks |
| L-05 | Calibration is user-declared, not sensed (ADR-004) | A wrong setting gives a mismatched animation edge | Calibration screen with diagram; Mac display picker |
| L-06 | Discovery needs a LAN passing mDNS and peer traffic | Guest/isolated Wi-Fi and some VPNs block discovery | E002 troubleshooting screen |
| L-07 | TLS 1.3 external-PSK is not supported by Network.framework | TLS 1.2 ECDHE-PSK is used instead (still AEAD with forward secrecy) | ADR-010; revisit with future SDKs |
| L-08 | One file at a time; multi-select queues by selection, not batch | Each file needs its own throw or Send | BR-08 is post-MVP |
| L-09 | Receiver outcome ledger is in memory | Rare duplicate after a Mac restart combined with a lost COMMITTED | SECURITY_REVIEW residual risk; persist ledger in P1 |
| L-10 | Overlay over some full-screen apps / Stage Manager varies by OS | May be hidden | Notification fallback (FR-210); T-10 on device |
| L-11 | Cross-device clock skew affects the "gesture → offer" metric | Metric is indicative only | Overlay start latency is measured locally on the Mac |
| L-12 | Physical-device acceptance not yet executed by the agent | Cross-device behaviour unverified | `Scripts/device-acceptance.md`; results go in TEST_REPORT |
| L-13 | No AWDL peer-to-peer on Android or Windows (ADR-013) | Android and Windows peers need a shared infrastructure Wi-Fi that passes mDNS; Windows also needs the network set to the Private profile | Troubleshooting copy (E002); `FirewallStatus` warns on Public networks; setup steps in `Scripts/device-acceptance.md` |
| L-14 | The Windows arrival overlay is best effort (ADR-008), and the Windows app has never run on Windows | Overlay placement, click-through and every Windows runtime path (DPAPI, DNS-SD, MotW, Hidden staging, firewall rule) are unverified | Notification fallback; Windows CI job and the cross-platform device matrix |
| L-15 | Android gesture works only inside the app, and sending requires the app in the foreground | No system-wide share-sheet throw; a long transfer can fail if the app is backgrounded | Same as L-01/L-02; the transfer survives activity recreation (`RecreationTest`) |
| L-16 | Post-pairing re-key window on the Mac | The first session right after pairing can get E004 while Bonjour re-announces the new session port | `ReceiverService` reports "Paired" only after the re-keyed listener is ready; senders retry E004 (Kotlin `SenderService`: 3× with backoff); interop `send-after-pair` |
| L-17 | Network.framework still offers and accepts plain-PSK suites (0x00A8/A9/AE/AF) | A downgraded peer can finish the TLS handshake, but is refused with E004 at `.ready` before `SESSION_AUTH` or any data (ADR-010) | `NetworkParameters.validateNegotiatedTLS`; `TLSCipherSuiteTests`; revisit if the SDK allows limiting PSK suites |
| L-18 | Mark-of-the-Web isn't applied on FAT/exFAT volumes or network shares | Files saved there have no Zone.Identifier, so SmartScreen/Office don't treat them as downloaded | Extension denylist still applies; recommend an NTFS destination folder |
| L-19 | Windows reset doesn't delete the identity seed | After unpairing everything, the Windows receiver keeps its peer ID | Unpair deletes the PSK and trust per peer; add a reset-all (SECURITY_REVIEW) |
| L-20 | The Windows firewall rule isn't port-scoped, and exists only for MSIX installs | The rule allows inbound TCP to `SpatialBridge.App.exe` on any port (Private profile only); unpackaged installs rely on the Windows firewall prompt | `Profile="private"` in `Package.appxmanifest`; `FirewallStatus` warning |
| L-21 | The lint logging check is a single-line heuristic and doesn't cover Swift | Multi-line or renamed-variable logging of filenames or secrets can get past `Scripts/lint.sh` | `Redaction.filename` by convention in Swift; code review |
| L-22 | Android NSD discovery not verified on a real network | Discovery has only run against the emulator's manual endpoint (`10.0.2.2`) | `TxtRecordsTest` covers the TXT merge; cross-platform device matrix |
| L-23 | The Kotlin core receiver (`JvmReceiverHost`, test-only) has no start-time staging purge | Only relevant to `sb-jvm`; stale `.sbpart` files would stay if the host were used directly | `sb-jvm serve` purges in the CLI (`Commands.kt`, interop `staging-purge`); not shipped in any app |
| L-24 | .NET decodes integers more strictly than Swift (rejects `1.0`) | A non-canonical peer that writes integers as `1.0` gets E012 from Windows but not from the Mac | Canonical JSON writes integers without a fraction (CONFORMANCE §1); all three senders comply |
