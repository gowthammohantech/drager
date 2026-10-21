# Known Limitations

| # | Limitation | Impact | Mitigation / plan |
|---|---|---|---|
| L-01 | iOS gesture works only inside the Spatial Bridge app | No system-wide Photos/Finder drag-off | Platform restriction (BRD out of scope) |
| L-02 | iOS sending requires the app in the foreground | Transfers stop if the app is backgrounded for long | Retry action, explicit messaging (BRD risk) |
| L-03 | Maximum file size 100 MiB in MVP | Larger files are rejected with E007 | `TransferLimits.maxFileBytes` |
| L-04 | No resume; interrupted transfers restart (ADR-011) | Large transfers on flaky Wi-Fi restart from zero | Protocol already carries offsets/acks |
| L-05 | Spatial calibration is user-declared, not sensed (ADR-004) | Wrong placement gives a mismatched animation edge | Calibration screen and recalibrate prompt |
| L-06 | Discovery needs a LAN that passes mDNS and peer traffic | Guest/isolated Wi-Fi or some VPNs block discovery | E002 troubleshooting copy |
