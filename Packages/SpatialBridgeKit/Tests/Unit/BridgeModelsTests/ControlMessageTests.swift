import Foundation
import Testing
@testable import BridgeModels

@Suite("Control message coding")
struct ControlMessageTests {
    private let peerA = PeerID(rawValue: String(repeating: "a", count: 32))
    private let peerB = PeerID(rawValue: String(repeating: "b", count: 32))

    private func sampleMessages() -> [ControlMessage] {
        let device = DeviceInfo(peerID: peerA, displayName: "Insane", platform: .iOS, model: "iPhone18,2")
        let offer = TransferOffer(
            transferID: UUID(),
            sourcePeerID: peerA,
            targetPeerID: peerB,
            filename: "IMG_0001.jpeg",
            contentType: "public.jpeg",
            byteCount: 10_485_760,
            sha256Hex: String(repeating: "0", count: 64),
            gesture: ExitGesture(edge: .top, normalizedPosition: 0.42, outwardVelocity: 812)
        )
        let id = offer.transferID
        return [
            .hello(Hello(device: device, sessionNonce: Data(repeating: 7, count: 32))),
            .pairRequest(PairRequest(ephemeralPublicKey: Data(repeating: 1, count: 32), signingPublicKey: Data(repeating: 2, count: 32), displayName: "Insane", challenge: Data(repeating: 3, count: 32))),
            .pairResponse(PairResponse(ephemeralPublicKey: Data(repeating: 4, count: 32), signingPublicKey: Data(repeating: 5, count: 32), displayName: "Mac", challenge: Data(repeating: 6, count: 32), transcriptSignature: Data(repeating: 9, count: 64))),
            .pairConfirm(PairConfirm(challengeResponse: Data(repeating: 8, count: 32), approvedPeerID: peerB, transcriptSignature: Data())),
            .pairReject(PairReject()),
            .transferOffer(offer),
            .transferAccept(TransferAccept(transferID: id, chunkBytes: 262_144)),
            .transferReject(TransferReject(transferID: id, reason: .sizeLimit, message: "too big")),
            .progress(TransferProgress(transferID: id, acknowledgedOffset: 1024)),
            .complete(TransferComplete(transferID: id, sha256Hex: String(repeating: "f", count: 64), byteCount: 10)),
            .committed(TransferCommitted(transferID: id, savedFilename: "IMG_0001 2.jpeg", byteCount: 10)),
            .error(TransferErrorMessage(transferID: id, code: .hashMismatch, message: nil)),
            .cancel(TransferCancel(transferID: id)),
            .ping(Ping(sequence: 1)),
            .pong(Ping(sequence: 1)),
        ]
    }

    @Test("Every message kind round-trips through JSON")
    func roundTrip() throws {
        for message in sampleMessages() {
            let data = try ControlMessageCoder.encode(message)
            let decoded = try ControlMessageCoder.decode(data)
            #expect(decoded.kind == message.kind)
            // Dates round-trip at millisecond precision, so compare the re-encoded bytes instead of values.
            let reencoded = try ControlMessageCoder.encode(decoded)
            #expect(reencoded == data, "re-encoding \(message.kind) changed bytes")
        }
        #expect(sampleMessages().count == ControlMessage.Kind.allCases.count)
    }

    @Test("Encoding is deterministic (sorted keys)")
    func deterministic() throws {
        let message = ControlMessage.progress(TransferProgress(transferID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, acknowledgedOffset: 5))
        let first = try ControlMessageCoder.encode(message)
        let second = try ControlMessageCoder.encode(message)
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self).hasPrefix(#"{"body":{"acknowledgedOffset":5"#))
    }

    @Test("Unknown kind fails to decode")
    func unknownKind() {
        let json = Data(#"{"kind":"NOPE","body":{}}"#.utf8)
        #expect(throws: (any Error).self) { try ControlMessageCoder.decode(json) }
    }

    @Test("Transfer IDs are surfaced for transfer-scoped messages")
    func transferIDs() {
        let id = UUID()
        #expect(ControlMessage.cancel(TransferCancel(transferID: id)).transferID == id)
        #expect(ControlMessage.ping(Ping(sequence: 0)).transferID == nil)
    }
}

@Suite("Transfer state machine")
struct TransferStateTests {
    @Test("Happy path transitions are legal")
    func happyPath() {
        let path: [TransferState] = [.created, .offered, .accepted, .streaming, .verifying, .committed, .completed]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from) → \(to)")
        }
    }

    @Test("Skipping states is illegal, failure is always reachable, terminal states are frozen")
    func rules() {
        #expect(!TransferState.created.canTransition(to: .streaming))
        #expect(TransferState.streaming.canTransition(to: .failed))
        #expect(TransferState.offered.canTransition(to: .canceled))
        #expect(!TransferState.completed.canTransition(to: .failed))
        #expect(!TransferState.failed.canTransition(to: .created))
        #expect(TransferState.completed.isTerminal && TransferState.failed.isTerminal && TransferState.canceled.isTerminal)
    }
}

@Suite("Model invariants")
struct ModelInvariantTests {
    @Test("ExitGesture clamps inputs")
    func gestureClamping() {
        let g = ExitGesture(edge: .left, normalizedPosition: 1.7, outwardVelocity: -3)
        #expect(g.normalizedPosition == 1)
        #expect(g.outwardVelocity == 0)
        #expect(ExitGesture(edge: .top, normalizedPosition: 0.5, outwardVelocity: 1500).intensity == 1)
    }

    @Test("All 14 FRD error codes exist with messages and suggestions")
    func errorCodes() {
        #expect(BridgeError.Code.allCases.count == 14)
        for code in BridgeError.Code.allCases {
            #expect(!code.userMessage.isEmpty)
            #expect(!code.recoverySuggestion.isEmpty)
            #expect(code.rawValue.hasPrefix("E"))
        }
    }

    @Test("Placement derives symmetric edges")
    func placement() {
        #expect(PhonePlacement.below.exitEdge == .top && PhonePlacement.below.arrivalEdge == .bottom)
        #expect(PhonePlacement.left.exitEdge == .right && PhonePlacement.left.arrivalEdge == .left)
        #expect(SpatialLayout(alignmentOffset: 3).alignmentOffset == 0.5)
    }

    @Test("PeerID validation")
    func peerID() {
        #expect(PeerID(validating: String(repeating: "a", count: 32)) != nil)
        #expect(PeerID(validating: String(repeating: "A", count: 32)) == nil)
        #expect(PeerID(validating: "short") == nil)
    }

    @Test("Connection quality classification")
    func quality() {
        #expect(ConnectionQuality(roundTripTime: nil) == .unknown)
        #expect(ConnectionQuality(roundTripTime: 0.005) == .excellent)
        #expect(ConnectionQuality(roundTripTime: 0.5) == .poor)
    }
}
