# Known Limitations

| # | Limitation | Impact | Mitigation / plan |
|---|---|---|---|
| L-01 | iOS gesture works only inside the Spatial Bridge app | No system-wide Photos/Finder drag-off | Platform restriction (BRD out of scope) |
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
