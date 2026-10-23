# Spatial Bridge conformance profile

Status: IN_PROGRESS

`PROTOCOL.md` defines what the messages are. This document pins down how they are encoded, which is what lets the Swift, Kotlin (`Apps/SpatialBridge-Android/core`) and .NET (`Apps/SpatialBridge-Windows/src/SpatialBridge.Core`) implementations interoperate.

The Swift implementation is the reference. If this document and the vectors in `Conformance/vectors/` disagree, the vectors win and this document gets fixed.

## 1. Canonical JSON (control frames, type 0x01)
- The top level is `{"body":{...},"kind":"KIND"}`. Kinds are listed in PROTOCOL.md; `PONG` reuses the `PING` body.
- **Key order:** keys are sorted by Unicode code point at every level. Output is compact, with no whitespace.
- **Strings:** UTF-8. Non-ASCII characters are written raw, never as `\uXXXX`. `/` is **not** escaped. Strings are not NFC-normalized.
  - `"` and `\` are escaped.
  - C0 controls: `\b \t \n \f \r` for those five, lowercase `\u00XX` for the rest.
  - DEL, NEL, U+2028 and U+2029 are written raw.
- **`Data`:** standard base64 with `=` padding and no line breaks. An empty `Data` is `""`; for example, the responder's `PAIR_CONFIRM.transcriptSignature` is empty.
- **Dates:** integer milliseconds since the Unix epoch. Swift stores dates relative to 2001, so a few half-millisecond values don't round naively. Cases marked `matchesNaiveRounding: false` in `canonical-json.json` show them. Ports encode their own millisecond integers and decode by reading the integer.
- **UUIDs:** uppercase canonical strings, `8-4-4-4-12`. Lowercase is accepted on input.
- **Peer IDs:** 32 lowercase hex characters, `hex(SHA256(ed25519_public_key)[0..16])`. Compare them as plain strings.
- **Optionals:** a nil optional is **omitted**, never written as `null`. This applies to `TransferReject.message`, `TransferErrorMessage.transferID` and `.message`, and `TransferOffer.gesture`.
- **Error codes:** strings `"E001"` to `"E014"`. **Never send a code or kind outside this set**, because older peers fail to decode the whole message.
- **Platform values:** `iOS`, `macOS`, `android`, `windows` (ADR-015). Receivers must accept unknown values.
- **Numbers:** integers have no fraction or exponent. Unsigned 64-bit fields (for example, chunk offsets in vectors) can exceed Int64. Doubles (gesture fields only) use the shortest round-trip form. They are not part of any hash.
- **Decoding:** unknown keys are ignored. Payloads larger than 65 536 bytes are rejected before parsing.

## 2. Binary layouts
- **Frame:** `type(1) | length UInt32BE | payload`. Check the length against the type's maximum before buffering the payload.
- **Chunk payload:** `transferID(16) | sequence UInt32BE | offset UInt64BE | bytes`.
  - The UUID is in **RFC 4122 byte order**. In .NET, use `Guid.ToByteArray(bigEndian: true)` or `TryWriteBytes(span, bigEndian: true, out _)`; the default byte order is mixed-endian.

## 3. Cryptography
| Item | Definition |
|---|---|
| Transcript | SHA-256 over `absorb(label, data) = utf8(label) ‖ UInt32BE(len) ‖ data`, labels in order: `sb-pair-v1` (empty), `ihello`, `rhello`, `ieph`, `reph`, `isig`, `rsig`, `ichal`, `rchal`. The HELLO entries are the **exact payload bytes sent and received** (ADR-014). |
| Key schedule | `HKDF-SHA256(ikm = X25519(shared), salt = transcript, info = "sb-pair-v1-keys", L = 96)`: bytes 0–31 are the SAS key, 32–63 the PSK, 64–95 the confirm key. |
| SAS | `UInt32BE(sasKey[0..4]) mod 1 000 000`, zero-padded to 6 digits. |
| Confirm | `HMAC-SHA256(confirmKey, "sb-confirm-v1:" ‖ role ‖ 0x1F ‖ utf8(approvedPeerID))`. `role` is `initiator` or `responder`. Compare in constant time. |
| Transcript signatures | Ed25519 over the 32-byte transcript hash. The responder signs in `PAIR_RESPONSE`, the initiator in `PAIR_CONFIRM`. |
| Session auth | Ed25519 over `"sb-session-v1" ‖ for each of [nonce_i, nonce_r, utf8(peerID_i), utf8(peerID_r), utf8(role)]: UInt32BE(len) ‖ bytes`. |
| TLS | TLS 1.2 only, suite 0xCCAC only. The PSK identity is `utf8(initiator peerID)` and the key is the 32-byte pair PSK. No resumption, tickets or renegotiation. |

CryptoKit Ed25519 signatures are not deterministic, so signature vectors are **verify-only**.

## 4. Behaviour
| Rule | Value |
|---|---|
| HELLO capabilities | pairing: exactly `["pair.v1"]`; session: defaults `transfer.v1`, `gesture.v1` with `session.v1` appended. `protocolVersion == 1`, nonce of 32 bytes, otherwise `ERROR E012`. |
| Handshake timeout | 30 s (pairing messages, TLS, transfer offer reply) |
| Session auth timeout | 15 s |
| Pairing user decision | 120 s |
| Keepalive | `PING` every 5 s from both sides; a peer is dead after 20 s of silence → E005 |
| Pairing rate limit | 3 failures per 60 s, per peer and globally; when locked, reply `PAIR_REJECT E003` |
| Transfer | chunk 256 KiB (max 512 KiB), max file 100 MiB, idle 30 s per frame, `PROGRESS` every 1 MiB and at the end, one transfer per session, a second offer → `TRANSFER_REJECT E012` |
| Replay | a known transfer ID gets its recorded outcome; a replayed success returns `COMMITTED` with no new file |
| Success | the sender shows success **only** after `COMMITTED` |
| Free space | must be at least size + 64 MiB |
| Offered filenames | must already equal `FilenameSanitizer.sanitize` output, so the extension is **lowercase** (`a.JPG` → E006). Senders sanitize before offering. |
| Windows names | `CON.txt`, `a<b>.txt` and the like pass `isSafe`; the Windows receiver maps them to a valid save name (ADR-015). |
| Mac policy | the Mac does not deny Windows executables (`.exe`, `.msi`, `.bat`, `.ps1`, `.lnk`, `.js`); the Windows receiver applies its own extension denylist. |

## 5. Shared CLI contract (`sb-swift`, `sb-jvm`, `sb-dotnet`)
These tools are for testing only and are never shipped in an app. Every command writes JSON-lines events to stdout. Events never contain filenames, file contents, PSKs or seeds; a PSK appears only as `pskFingerprint = hex(SHA256(psk))[0..16]`.

```
<cli> tls-echo  --role server|client --listen HOST:PORT | --connect HOST:PORT --identity ID --psk-hex HEX
<cli> serve     --state DIR --listen 127.0.0.1:0 --dest DIR --decision approve|reject [--test-mode]
<cli> pair-initiate --state DIR --connect HOST:PORT --decision approve|reject [--test-mode]
<cli> pair-respond  --state DIR --listen 127.0.0.1:0 --decision approve|reject [--test-mode]
<cli> send      --state DIR --connect HOST:PORT --file PATH [--content-type UTI] [--transfer-id UUID] [--fault NAME]
<cli> unpair    --state DIR --peer PEERID
```
- `--state DIR` holds the identity seed and the trusted peers as JSON. These files are test-only and unencrypted.
- `serve` advertises nothing. It prints `{"event":"listening","pairingPort":N,"sessionPort":M}`. Before it listens, it deletes `<state>/staging/*.sbpart` files whose mtime is 24 h old or older, like the apps' receivers do at launch.
- `unpair` removes `PEERID`'s trust entry and pair PSK from `--state`, prints `{"event":"unpaired","peerID":PEERID}` and exits 0. It is idempotent: an unknown peer also exits 0. A malformed `--peer` is a usage error (exit 64).
  - A `serve` running on the same state directory picks the change up while it runs. It polls the state's PSKs about every 200 ms, prints its own `unpaired` `{peerID}`, and refuses that peer's next session with E004 on both sides. The interop matrix's `after-unpair` scenario checks this.
- **Events:**
  - `listening`
  - `sas` `{code}`
  - `paired` `{peerID, pskFingerprint}`
  - `pairFailed` `{code}`
  - `sessionReady`
  - `progress` `{offset}`
  - `committed` `{transferID, byteCount, sha256Hex}`
  - `error` `{code}`
  - `unpaired` `{peerID}`
  - `done`
- **Exit code:** 0 on success. On failure, the numeric part of the error code (E004 → 4).
- **Faults for `send`:**
  - `corrupt-chunk`
  - `out-of-order`
  - `cancel-mid`
  - `oversize-offer`
  - `unsafe-name`
  - `stall` (go quiet after the offer)

## 6. Vector files (`Conformance/vectors/*.json`)
Each file is `{"version":1,"kind":"<name>","cases":[{"name":..., ...}]}` and follows `Conformance/schema/vectors.schema.json`.

All bytes are lowercase hex. The Swift `VectorExportTests` target generates the files. In CI it runs in check mode and fails on any difference.

| File | Each case contains |
|---|---|
| `framing.json` | `frameType`, field values, `hex` of the encoded frame; plus `invalid` cases with the expected error |
| `control-messages.json` | `kind`, `json` (exact canonical UTF-8 string), `hex` |
| `canonical-json.json` | `input` (string as code points), `json` (encoded string literal) |
| `pairing.json` | the fixed private keys and nonces, both HELLO hex payloads, `transcriptHash`, `okm`, `sas`, `psk`, `confirmInitiator`, `confirmResponder`, both peer IDs |
| `session-auth.json` | the inputs plus `signedContext` hex |
| `ed25519.json` | `publicKey`, `message`, `signature`, `valid` |
| `sanitizer.json` | `input`, `contentType`, `sanitized`, `isSafe` |
| `uti-policy.json` | `filename`, `contentType`, `allowedOnMac` |
| `coordinate-mapper.json` | layout, display frames, gesture, expected placement |
