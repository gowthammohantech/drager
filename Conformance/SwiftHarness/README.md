# sb-swift: Swift conformance harness

A test-only CLI that runs the Swift reference implementation (SpatialBridgeKit) over real Network.framework loopback connections. It implements the shared CLI contract in [docs/API/CONFORMANCE.md §5](../../docs/API/CONFORMANCE.md). It is never shipped in an app.

It is a separate SwiftPM package with a path dependency on `Packages/SpatialBridgeKit`, so the kit itself stays free of dependencies. It has no remote dependencies.

## Build
```sh
swift build -c release --package-path Conformance/SwiftHarness
BIN="$(swift build -c release --package-path Conformance/SwiftHarness --show-bin-path)/sb-swift"
```

## Output
- **stdout:** one JSON object per line, with sorted keys. Events never contain filenames, file contents, PSKs or seeds. A PSK appears only as `pskFingerprint = hex(SHA256(psk))[0..16]`.
- **stderr:** usage errors only.
- **Exit code:**
  - 0 on success.
  - Otherwise the numeric part of the error code (E004 → 4).
  - 64 for bad arguments.

## Commands

### tls-echo
A TLS 1.2 PSK echo using the production `NetworkParameters`: suite 0xCCAC only, with no tickets, resumption or renegotiation. The PSK identity is the UTF-8 bytes of `--identity`.
```sh
$BIN tls-echo --role server --listen 127.0.0.1:0    --identity ID --psk-hex <64 hex>
$BIN tls-echo --role client --connect 127.0.0.1:N   --identity ID --psk-hex <64 hex>
```
- **Server:**
  - Prints `{"event":"listening","port":N,"pskFingerprint":…}`.
  - For each connection it prints `{"event":"tlsEstablished"}` and echoes every byte back.
  - A failed handshake prints `{"code":"E004","event":"error"}`, and the server keeps running. Stop it with a signal.
- **Client:**
  - Sends `ping\n` and expects the same bytes back.
  - On success it prints `tlsEstablished`, then `echoOk`, and exits 0.
  - On any failure it prints `{"event":"error","code":"E004","cause":…}` and exits 4.

### pair-respond / pair-initiate
These run the pairing handshake (`PairingProtocol`) over plain TCP. `--decision` answers the SAS prompt automatically.
```sh
$BIN pair-respond  --state R --listen 127.0.0.1:0 --decision approve
#   {"event":"listening","pairingPort":N,"port":N}
$BIN pair-initiate --state I --connect 127.0.0.1:N --decision approve
```
- **On success, both sides print:**
  - `sas {code}`
  - `paired {peerID, pskFingerprint}` (`peerID` is the other side's ID)
  - `done`
  - Both then exit 0, and the `sas` and `pskFingerprint` values match on both sides.
- **On failure:**
  - The tool prints `pairFailed {code}`. A rejection gives `E003` and exit 3.
  - `pair-respond` handles one pairing attempt and then exits.

### serve
The receiver role, like the Mac. It runs a pairing listener and a TLS-PSK session listener on the given host. It advertises nothing over Bonjour.
```sh
$BIN serve --state S --listen 127.0.0.1:0 --dest OUT --decision approve [--session-port M] [--test-mode]
#   {"event":"listening","pairingPort":N,"sessionPort":M}
```
- **Ports:** `--listen` sets the pairing port. The session port is ephemeral unless you pass `--session-port`.
- **Pairing:** prints `sas`, then `paired`, or `pairFailed`.
- **Session listener:**
  - After each successful pairing, the session listener is rebuilt on the same port with the new PSK, because Network.framework fixes the PSK set when a listener is created.
  - A session with an unknown PSK prints `error {code:E004}`.
- **Sessions:**
  - Each authenticated session prints `sessionReady {peerID}`.
  - It then runs `TransferReceiver` into `--dest`, printing `progress {offset}` (every 1 MiB and at the end), `committed {transferID, byteCount, sha256Hex}`, or `error {code}` for each transfer.
  - A replayed transfer ID is answered from the outcome ledger and writes no new file.
- **Lifetime:** runs until it is killed.

### send
The sender role, like the iPhone. It does TLS-PSK, then `SessionAuthenticator`, then `TransferSender`.
```sh
$BIN send --state I --connect 127.0.0.1:M --file PATH [--content-type UTI] [--transfer-id UUID] [--peer PEERID] [--fault NAME] [--test-mode]
```
- **Target peer:** the trusted peer named by `--peer`, or by default the most recently paired one.
- **Output:**
  - Prints `sessionReady`.
  - Then prints `progress {offset}` at 1 MiB steps. Each offset is the bytes the receiver has acknowledged, or the bytes sent before the first acknowledgement arrives.
  - Exits 0 only after `COMMITTED`, printing `committed {transferID, byteCount, sha256Hex}` and then `done`.
  - On failure it prints `error {code}` and exits with the numeric code.

#### Faults
The faults bypass `TransferSender` and send hand-built frames. Results against `sb-swift serve`:

| `--fault` | What the sender does | Result |
|---|---|---|
| `corrupt-chunk` | flips byte 0 of chunk 0; the offer and COMPLETE carry the real digest | `E010`, exit 10 |
| `out-of-order` | sends chunk #1 (sequence 1) first; a file with one chunk sends chunk 0 with sequence 1 | `E012`, exit 12 |
| `cancel-mid` | sends one chunk, then `CANCEL` | `E013`, exit 13 |
| `oversize-offer` | offers `byteCount = 100 MiB + 1` | `TRANSFER_REJECT E007`, exit 7 |
| `unsafe-name` | offers the filename `../sb-unsafe.txt` | `TRANSFER_REJECT E006`, exit 6 |
| `stall` | goes quiet after the offer; keepalive pings continue | `E014` after the receiver's idle timeout, exit 14 |

For each fault, both sides print the same error code, and the receiver's staging folder is left empty.

### --test-mode
`--test-mode` shortens the timeouts so fault runs finish quickly:
- handshake: 10 s
- pairing decision: 10 s
- transfer idle: 5 s, instead of 30 s

For example, `stall` against `serve --test-mode` fails after about 5 s.

## State directory (`--state DIR`)
These files are test-only and **unencrypted**:
- `secrets.json`: base64 values for the keys `identity.ed25519.seed` and `pair.psk.<peerID>`. This is a file-backed `SecretStore`.
- `trusted-peers.json`: the `TrustedPeerStore` file.
- `staging/`: the receiver's `.sbpart` staging area.

Delete the directory to reset the identity.

## Loopback example
```sh
$BIN serve --state /tmp/s --listen 127.0.0.1:0 --dest /tmp/out --decision approve &
# Read pairingPort and sessionPort from the first line, then:
$BIN pair-initiate --state /tmp/c --connect 127.0.0.1:$PAIRING --decision approve
$BIN send --state /tmp/c --connect 127.0.0.1:$SESSION --file /tmp/rand.bin
```
