# Spatial Bridge wire protocol v1

Status: IMPLEMENTED (BridgeModels, BridgeNetworking, BridgeTransfer)

## Platforms
Four implementations share this protocol: iOS (sender) and macOS (receiver) in Swift, Android (sender) in Kotlin, and Windows (receiver) in C# (ADR-013).
The exact encoding rules, test vectors and the shared test CLI are in [CONFORMANCE.md](CONFORMANCE.md).
`device.platform` and the TXT `plat` key take the values `iOS`, `macOS`, `android` or `windows`. Peers must accept unknown values (ADR-015).

## Transport
- Discovery: Bonjour `_spatialbridge._tcp` in `local.`. The Mac advertises and the iPhone browses. TXT keys: `pid` (peer ID hint), `name`, `plat`, `pv` (protocol version). TXT data is **untrusted**.
- **Pairing connection:** plain TCP, used only for the pairing handshake below. No file data or secrets are ever sent on it.
- **Session connection:** TLS 1.2 with an external pre-shared key, suite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` only (TLS 1.3 PSK-only is unsupported by Network.framework; see ADR-010). Identity = the initiator's peer ID (UTF-8). Key = the 32-byte pair PSK. Resumption, tickets and renegotiation are disabled. An unknown identity fails the handshake.
- **Session authentication:** after TLS, each side sends `HELLO(session.v1)` and then `SESSION_AUTH`, an Ed25519 signature over `"sb-session-v1" ‖ len‖nonce_i ‖ len‖nonce_r ‖ len‖peerID_i ‖ len‖peerID_r ‖ len‖role`. It is verified against the stored pairing key.
- **Advertisement:** a session instance (`role=session`) and, while pairing is enabled, a pairing instance (`role=pairing`), both of type `_spatialbridge._tcp`.
- On the pairing connection, the first frame from the initiator is `HELLO` with capability `pair.v1`. On a session connection the capability is `session.v1`.

## Framing
```
+------+-----------------+--------------------+
| type | length UInt32BE | payload (length B) |
+------+-----------------+--------------------+
0x01 control: UTF-8 JSON ControlMessage, length ≤ 65 536
0x02 chunk:   transferID (16 B UUID) | sequence UInt32BE | offset UInt64BE | bytes (≤ 524 288)
```
The header is parsed and the length checked against the type's maximum **before** the payload is buffered. An unknown type or an oversized length closes the connection (E012).

## Control messages
JSON object `{"kind": KIND, "body": {...}}`, sorted keys, `Data` as base64, dates as integer milliseconds.

| Kind | Direction | Body |
|---|---|---|
| HELLO | both | protocolVersion, device{peerID, displayName, platform, model}, capabilities, sessionNonce(32 B) |
| PAIR_REQUEST | i→r | ephemeralPublicKey (X25519), signingPublicKey (Ed25519), displayName, challenge(32 B) |
| PAIR_RESPONSE | r→i | ephemeralPublicKey, signingPublicKey, displayName, challenge, transcriptSignature |
| PAIR_CONFIRM | both | challengeResponse = HMAC(confirmKey, "sb-confirm-v1:" role 0x1F approvedPeerID), approvedPeerID, transcriptSignature (initiator only) |
| PAIR_REJECT | both | reason (E003/E004) |
| TRANSFER_OFFER | i→r | protocolVersion, transferID, sourcePeerID, targetPeerID, filename (sanitized), contentType (UTI), byteCount, sha256Hex, gesture{edge, normalizedPosition, outwardVelocity, travelDistance, firedAt}, createdAt |
| TRANSFER_ACCEPT | r→i | transferID, chunkBytes |
| TRANSFER_REJECT | r→i | transferID, reason, message |
| PROGRESS | r→i | transferID, acknowledgedOffset |
| COMPLETE | i→r | transferID, sha256Hex, byteCount |
| COMMITTED | r→i | transferID, savedFilename, byteCount |
| ERROR | both | transferID?, code, message |
| CANCEL | both | transferID, reason |
| PING / PONG | both | sequence, sentAt |

## Pairing key schedule
`transcriptHash = SHA256(labelled, length-prefixed: both HELLOs, both X25519 keys, both Ed25519 keys, both challenges)`.
`okm = HKDF-SHA256(X25519(shared), salt = transcriptHash, info = "sb-pair-v1-keys", 96 B)`: bytes 0–31 give the SAS key (6 digits = first 4 bytes BE mod 10⁶), 32–63 give the PSK, and 64–95 give the confirm key.
The responder signs the transcript hash in PAIR_RESPONSE. The initiator signs it in PAIR_CONFIRM. Each side verifies the other's signature against the received Ed25519 key, and the peer ID is `hex(SHA256(ed25519)[0..16])`.

## Transfer sequence
1. Sender sends `TRANSFER_OFFER` before any bytes (FR-105).
2. Receiver validates trust, protocol version, filename safety, UTType policy, size ≤ limit and free space (FR-203). It replies `TRANSFER_ACCEPT` or `TRANSFER_REJECT`.
3. Sender streams chunks with contiguous sequences and offsets, at most 4 in flight. Receiver enforces `offset == expected` and `sequence == expected` and writes each chunk to a `.sbpart` staging file, updating SHA-256 incrementally. It may send `PROGRESS` acks.
4. Sender sends `COMPLETE`. Receiver checks byteCount and digest against both the offer and `COMPLETE`, fsyncs, and atomically moves the file into the destination with collision-safe naming. Only then does it reply `COMMITTED` (FR-209).
5. Any failure → `ERROR`/`CANCEL`, the staging file is removed, and the outcome is recorded.

## Idempotency and replay
- Sessions are bound to fresh HELLO nonces under TLS. TLS provides record-level replay protection.
- The receiver keeps an outcome ledger of terminal transfer IDs. A repeated offer or COMPLETE for a known ID is answered with the recorded outcome (or ERROR) and never creates a second file.
- One transfer per session at a time (ADR-007). A second offer while one is active is rejected with E012.

## Timeouts
Handshake 30 s, transfer idle 30 s (`TransferLimits`). Ping every 5 s while connected. Three missed pongs → E005.
