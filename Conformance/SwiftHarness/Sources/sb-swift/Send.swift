import Foundation
import Network
import BridgeCore
import BridgeModels
import BridgeNetworking
import BridgeSecurity
import BridgeTransfer
import os

enum Fault: String, CaseIterable {
    case corruptChunk = "corrupt-chunk"
    case outOfOrder = "out-of-order"
    case cancelMid = "cancel-mid"
    case oversizeOffer = "oversize-offer"
    case unsafeName = "unsafe-name"
    case stall
}

/// `send`: sender role (like the iPhone). Exits 0 only after COMMITTED.
enum SendCommand {
    static func run(_ args: Args) async -> Int32 {
        do {
            let state = try HarnessState(path: try args.required("state"))
            let file = URL(fileURLWithPath: try args.required("file"))
            let (host, port) = try args.hostPort("connect")
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw UsageError("bad port") }
            let fault = try args.optional("fault").map { raw -> Fault in
                guard let f = Fault(rawValue: raw) else { throw UsageError("unknown --fault") }
                return f
            }
            let transferID = try args.optional("transfer-id").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw UsageError("--transfer-id must be a UUID") }
                return id
            } ?? UUID()
            let outgoing = OutgoingFile(url: file, contentType: args.optional("content-type"))
            let limits = HarnessTimeouts(testMode: args.flag("test-mode")).limits

            guard let peer = await state.targetPeer(args.optional("peer")),
                  let psk = try state.pairSecrets.psk(for: peer.peerID) else {
                throw BridgeError(.authenticationFailed, detail: "no trusted peer in state")
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(host), port: nwPort,
                using: NetworkParameters.clientSession(identity: state.identity.peerID, preSharedKey: psk)
            )
            let transport = try await NWFrameTransport.open(connection, limits: limits, timeout: .seconds(30))
            let channel = SessionChannel(transport: transport, configuration: .session)
            defer { Task { await channel.close() } }
            _ = try await SessionAuthenticator.authenticateAsInitiator(
                channel: channel, identity: state.identity, device: state.device(platform: .iOS), expectedPeer: peer
            )
            Out.event("sessionReady", ["peerID": peer.peerID.rawValue])

            let committed: TransferCommitted
            let sha: String
            if let fault {
                (committed, sha) = try await FaultSender(
                    channel: channel, local: state.identity.peerID, remote: peer.peerID, limits: limits
                ).send(outgoing, transferID: transferID, fault: fault)
            } else {
                sha = try await TransferSender.prepare(outgoing, limits: limits).sha256Hex
                let reporter = ProgressReporter()
                let sender = TransferSender(channel: channel, localPeerID: state.identity.peerID, remotePeerID: peer.peerID, limits: limits)
                committed = try await sender.send(outgoing, transferID: transferID, gesture: nil) { snapshot in
                    reporter.report(snapshot)
                }
            }
            Out.event("committed", [
                "transferID": committed.transferID.uuidString,
                "byteCount": Int(committed.byteCount),
                "sha256Hex": sha,
            ])
            Out.event("done")
            await channel.close()
            return 0
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            let code = bridgeCode(error)
            Out.error(code)
            return exitCode(for: code)
        }
    }
}

/// Turns `TransferSender` snapshots into `progress` events at 1 MiB steps
/// and at the end (bytes acknowledged by the receiver, or sent before the first ack).
final class ProgressReporter: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: Int64(0))

    func report(_ snapshot: TransferProgressSnapshot) {
        guard snapshot.state == .streaming || snapshot.state == .verifying || snapshot.state == .completed else { return }
        let offset = snapshot.bytesTransferred
        let atStep = offset % (1 << 20) == 0 || offset == snapshot.totalBytes
        guard offset > 0, atStep else { return }
        let emit = last.withLock { last -> Bool in
            guard offset > last else { return false }
            last = offset
            return true
        }
        if emit { Out.event("progress", ["offset": Int(offset)]) }
    }
}

/// Hand-built frames that bypass `TransferSender` to inject protocol faults.
struct FaultSender {
    let channel: SessionChannel
    let local: PeerID
    let remote: PeerID
    let limits: TransferLimits

    static let unsafeFilename = "../sb-unsafe.txt"

    func send(_ file: OutgoingFile, transferID: UUID, fault: Fault) async throws -> (TransferCommitted, String) {
        let (sha, realCount) = try await FileHasher.sha256Hex(of: file.url)
        var offer = TransferOffer(
            transferID: transferID,
            sourcePeerID: local,
            targetPeerID: remote,
            filename: FilenameSanitizer.sanitize(file.filename, contentType: file.contentType),
            contentType: file.contentType,
            byteCount: realCount,
            sha256Hex: sha,
            gesture: nil
        )
        switch fault {
        case .oversizeOffer: offer.byteCount = limits.maxFileBytes + 1
        case .unsafeName: offer.filename = Self.unsafeFilename
        default: break
        }

        await channel.drainInbox()
        try await channel.send(.transferOffer(offer))
        let accept: TransferAccept
        switch try await channel.receiveControl(timeout: limits.handshakeTimeout) {
        case .transferAccept(let a) where a.transferID == transferID: accept = a
        case .transferReject(let r) where r.transferID == transferID: throw BridgeError(r.reason, detail: "rejected")
        case .committed(let c) where c.transferID == transferID: return (c, sha)
        case .error(let e): throw BridgeError(e.code, detail: "receiver error")
        default: throw BridgeError(.protocolMismatch, detail: "expected TRANSFER_ACCEPT")
        }
        let chunkBytes = max(1, min(accept.chunkBytes, limits.chunkBytes, limits.maxChunkBytes))
        let channel = channel
        let total = realCount

        return try await withThrowingTaskGroup(of: TransferCommitted?.self) { group in
            group.addTask {
                try await writeChunks(file: file.url, id: transferID, chunkBytes: chunkBytes, total: total, sha: sha, fault: fault)
                return nil
            }
            group.addTask {
                // Generous deadline: the receiver's idle timeout decides `stall`.
                while true {
                    switch try await channel.receiveControl(timeout: limits.transferIdleTimeout * 4 + .seconds(10)) {
                    case .progress(let p) where p.transferID == transferID:
                        Out.event("progress", ["offset": Int(p.acknowledgedOffset)])
                    case .committed(let c) where c.transferID == transferID:
                        return c
                    case .error(let e):
                        throw BridgeError(e.code, detail: "receiver error")
                    case .transferReject(let r) where r.transferID == transferID:
                        throw BridgeError(r.reason, detail: "rejected")
                    case .cancel(let c) where c.transferID == transferID:
                        throw BridgeError(.transferCanceled, detail: "receiver cancelled")
                    default:
                        continue
                    }
                }
            }
            while let result = try await group.next() {
                if let committed = result {
                    group.cancelAll()
                    return (committed, sha)
                }
            }
            throw BridgeError(.peerLost, detail: "no COMMITTED")
        }
    }

    private func writeChunks(file: URL, id: UUID, chunkBytes: Int, total: Int64, sha: String, fault: Fault) async throws {
        if fault == .stall { return } // Go quiet after the offer.
        let reader = try ChunkedFileReader(url: file, chunkBytes: chunkBytes)
        var chunks: [(offset: Int64, data: Data)] = []
        var sequence: UInt32 = 0

        func emit(_ seq: UInt32, _ offset: Int64, _ data: Data) async throws {
            try await channel.send(.chunk(ChunkFrame(transferID: id, sequence: seq, offset: UInt64(offset), payload: data)))
        }

        switch fault {
        case .outOfOrder:
            // Send the second chunk first (or, for a one-chunk file, the first chunk with sequence 1).
            if let first = try await reader.next() { chunks.append(first) }
            if let second = try await reader.next() {
                try await emit(1, second.offset, second.data)
            } else if let first = chunks.first {
                try await emit(1, first.offset, first.data)
            }
            await reader.close()
            return
        case .cancelMid:
            if let first = try await reader.next() { try await emit(0, first.offset, first.data) }
            await reader.close()
            try await channel.send(.cancel(TransferCancel(transferID: id)))
            return
        default:
            break
        }

        while let (offset, data) = try await reader.next() {
            var payload = data
            if fault == .corruptChunk, sequence == 0, !payload.isEmpty {
                payload[payload.startIndex] ^= 0xFF
            }
            try await emit(sequence, offset, payload)
            sequence &+= 1
        }
        await reader.close()
        try await channel.send(.complete(TransferComplete(transferID: id, sha256Hex: sha, byteCount: total)))
    }
}
