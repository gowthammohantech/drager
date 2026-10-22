# Security Review (AD §6 threat model)

Reviewed against the implementation on 2026-10-21. Every mitigation points to code and, where possible, a test.

| Threat | Mitigation | Code | Test |
|---|---|---|---|
| Impersonation of a Mac or iPhone | Pairing binds Ed25519 identity keys to an X25519 exchange; the user compares the SAS; sessions need the per-pair PSK **and** an Ed25519 signature over fresh nonces | `PairingProtocol`, `SessionAuthenticator`, `NetworkParameters` | `PairingProtocolTests.tamperedKeyDetected`, `spoofedPeerID`, `SessionAuthenticatorTests.*` |
| Malicious Bonjour records | TXT data is display-only. The advertised peer ID must match the authenticated key after pairing | `BonjourBrowser`, `SenderService.pair` | code review |
| Man-in-the-middle during pairing | 6-digit SAS from HKDF over the full transcript; the responder signs the transcript; confirmation HMACs | `PairingCrypto`, `PairingProtocol` | `PairingCryptoTests`, `tamperedKeyDetected` |
| SAS brute force | 3 failures per peer, plus a global bucket, then a 60 s lockout; one pairing at a time; the pairing listener is only up while "Allow new pairings" is on | `PairingRateLimiter`, `ReceiverService.handlePairing` | `PairingProtocolTests.rateLimited` |
| Replay | Fresh 32-byte nonces in every HELLO, signed in SESSION_AUTH; TLS record protection; the transfer outcome ledger refuses to write a committed ID twice | `SessionAuthenticator`, `TransferOutcomeLedger` | `replayIsIdempotent`, `retrySameID` |
| Passive eavesdropping and key compromise | TLS 1.2 ECDHE-PSK ChaCha20-Poly1305 (forward secrecy); resumption and tickets disabled | `NetworkParameters` | `NetworkLoopbackTests` |
| Unauthorised peer sends a file | Unknown PSK identity fails TLS; untrusted peer ID fails SESSION_AUTH; offer source must equal the authenticated peer | `ServiceAdvertiser`, `SessionAuthenticator`, `TransferReceiver.validate` | `unknownIdentityRejected`, `untrusted`, `spoofedSource` |
| Path traversal and unsafe names | Sanitizer keeps only the last component, strips control characters and leading dots, NFC, 255-byte cap; the receiver rejects names that aren't already sanitized; exclusive rename; the final path is checked to be inside the folder | `FilenameSanitizer`, `TransferPolicy`, `FolderDestinationStore.commit` | `traversalRejected`, sanitizer tests |
| Oversized frames and memory exhaustion | Header length is checked against per-type caps before buffering; bounded inbox; one transfer per session; at most 8 pending handshakes | `FrameCodec`, `SessionChannel`, `ServiceAdvertiser` | `FrameCodecTests`, `chunkStream` |
| Disk exhaustion | Free space ≥ size + 64 MiB headroom before accept; 100 MiB cap; staging purged after 24 h | `TransferReceiver.validate`, `StagingArea.purge` | `diskFull`, `purge` |
| Tampered chunks | Strict sequence and offset; SHA-256 verified against both the offer and COMPLETE before commit | `TransferReceiver.receive` | `corruptedChunk` |
| Executable delivery | Denied UTTypes (apps, scripts, executables); `LSFileQuarantineEnabled` so Gatekeeper checks anything opened | `TransferPolicy.defaultDeniedTypes`, macOS Info.plist | `deniedType` |
| Secret leakage | Identity seed and PSKs in the Keychain (`AfterFirstUnlockThisDeviceOnly`, data-protection keychain); never logged; unpair deletes them | `KeychainSecretStore`, `PairSecretStore` | `PairingCryptoTests` (stores) |
| Sensitive logs | `Redaction.filename`, peer short IDs, `Scrubber` on export; analytics carry only buckets, durations and codes | `BridgeDiagnostics` | `DiagnosticsTests` |
| Least privilege | iOS: PhotosPicker (no library entitlement), no background modes. macOS: sandbox, user-selected folder, app-scoped bookmark, hardened runtime | entitlements, xcconfigs | review |
| Custom crypto | Only CryptoKit primitives (X25519, Ed25519, HKDF, HMAC, SHA-256) and the system TLS stack | — | — |

## Residual risks
- The pairing connection is plain TCP until the SAS is confirmed. Its security rests on users actually comparing codes (standard SAS assumption).
- The TLS 1.2 PSK identity (the iPhone peer ID) is visible on the wire. It is a public key fingerprint, not a secret.
- The outcome ledger lives in memory. After a Mac app restart, a lost COMMITTED for a completed transfer could lead to a retry being saved as "name 2". This needs a lost acknowledgement *and* a restart in between.
