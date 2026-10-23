import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeSecurity

enum ControlMessageVectors {
    static func cases() throws -> [VectorCase] {
        var out: [VectorCase] = []
        let phone = Fixtures.phone.peerID
        let mac = Fixtures.mac.peerID
        let id = Fixtures.transferID

        func add(_ name: String, _ message: ControlMessage, extra: VectorCase = [:]) throws {
            let data = try ControlMessageCoder.encode(message)
            #expect(data.count <= TransferLimits.default.maxControlFrameBytes)
            let decoded = try ControlMessageCoder.decode(data)
            #expect(decoded.kind == message.kind)
            #expect(try ControlMessageCoder.encode(decoded) == data, "\(name) does not re-encode to the same bytes")
            var c: VectorCase = [
                "name": .string(name), "kind": .string(message.kind.rawValue),
                "json": .string(String(decoding: data, as: UTF8.self)), "hex": .hex(data),
            ]
            c.merge(extra) { a, _ in a }
            out.append(c)
        }

        // HELLO, one per platform and per connection purpose.
        let phoneDevice = Fixtures.device(Fixtures.phone, "Insane", .iOS, "iPhone18,2")
        try add("HELLO iOS pairing", .hello(Hello(device: phoneDevice, capabilities: [Hello.pairingCapability], sessionNonce: counting(from: 0x10))))
        var session = Hello(device: phoneDevice, sessionNonce: counting(from: 0x20))
        session.capabilities.append(Hello.sessionCapability)
        try add("HELLO iOS session", .hello(session))
        var macSession = Hello(device: Fixtures.device(Fixtures.mac, "Studio Mac", .macOS, "Mac16,1"), sessionNonce: counting(from: 0x30))
        macSession.capabilities.append(Hello.sessionCapability)
        try add("HELLO macOS session", .hello(macSession))
        try add("HELLO android default capabilities", .hello(Hello(device: Fixtures.device(Fixtures.android, "Pixel", .android, "Pixel 9"), sessionNonce: counting(from: 0x40))))
        try add("HELLO windows pairing", .hello(Hello(device: Fixtures.device(Fixtures.windows, "Desk PC", .windows, "Surface Laptop 7"), capabilities: [Hello.pairingCapability], sessionNonce: counting(from: 0x50))))
        try add("HELLO unknown platform value is preserved", .hello(Hello(device: Fixtures.device(Fixtures.android, "Future", DevicePlatform(rawValue: "visionOS"), "X"), sessionNonce: counting(from: 0x60))))
        let longName = String(repeating: "Ab😀é", count: 20) // 80 grapheme clusters
        try add("HELLO displayName truncated to 64 grapheme clusters", .hello(Hello(device: Fixtures.device(Fixtures.phone, longName, .iOS, "iPhone18,2"), sessionNonce: counting(from: 0x70))), extra: [
            "displayNameInput": .string(longName),
        ])

        // Pairing.
        try add("PAIR_REQUEST", .pairRequest(PairRequest(ephemeralPublicKey: Data(repeating: 1, count: 32), signingPublicKey: Data(repeating: 2, count: 32), displayName: "Insane", challenge: Data(repeating: 3, count: 32))))
        try add("PAIR_RESPONSE", .pairResponse(PairResponse(ephemeralPublicKey: Data(repeating: 4, count: 32), signingPublicKey: Data(repeating: 5, count: 32), displayName: "Mac", challenge: Data(repeating: 6, count: 32), transcriptSignature: Data(repeating: 9, count: 64))))
        try add("PAIR_CONFIRM initiator (64-byte transcript signature)", .pairConfirm(PairConfirm(challengeResponse: Data(repeating: 8, count: 32), approvedPeerID: mac, transcriptSignature: Data(repeating: 0xAB, count: 64))))
        try add("PAIR_CONFIRM responder (empty transcriptSignature)", .pairConfirm(PairConfirm(challengeResponse: Data(repeating: 8, count: 32), approvedPeerID: phone, transcriptSignature: Data())))
        try add("PAIR_REJECT default reason", .pairReject(PairReject()))
        try add("PAIR_REJECT authentication failed", .pairReject(PairReject(reason: .authenticationFailed)))
        try add("SESSION_AUTH", .sessionAuth(SessionAuth(signature: Data(repeating: 4, count: 64))))

        // Transfer.
        func offer(_ gesture: ExitGesture?) -> TransferOffer {
            TransferOffer(transferID: id, sourcePeerID: phone, targetPeerID: mac, filename: "IMG_0001.jpeg", contentType: "public.jpeg", byteCount: 10_485_760, sha256Hex: String(repeating: "0", count: 64), gesture: gesture, createdAt: Fixtures.date)
        }
        try add("TRANSFER_OFFER with gesture", .transferOffer(offer(Fixtures.gesture)))
        try add("TRANSFER_OFFER without gesture", .transferOffer(offer(nil)))
        try add("TRANSFER_OFFER non-ASCII filename", .transferOffer(TransferOffer(transferID: id, sourcePeerID: phone, targetPeerID: mac, filename: "Café “menu” 😀.pdf", contentType: "com.adobe.pdf", byteCount: 1, sha256Hex: String(repeating: "a", count: 64), gesture: ExitGesture(edge: .left, normalizedPosition: 0, outwardVelocity: 0, travelDistance: 0, firedAt: Date(timeIntervalSince1970: 0)), createdAt: Date(timeIntervalSince1970: 0))))
        try add("TRANSFER_ACCEPT", .transferAccept(TransferAccept(transferID: id, chunkBytes: 262_144)))
        try add("TRANSFER_REJECT with message", .transferReject(TransferReject(transferID: id, reason: .sizeLimit, message: "too big")))
        try add("TRANSFER_REJECT without message", .transferReject(TransferReject(transferID: id, reason: .protocolMismatch)))
        try add("PROGRESS", .progress(TransferProgress(transferID: id, acknowledgedOffset: 1_048_576)))
        try add("PROGRESS large offset", .progress(TransferProgress(transferID: id, acknowledgedOffset: 104_857_600)))
        try add("COMPLETE", .complete(TransferComplete(transferID: id, sha256Hex: String(repeating: "f", count: 64), byteCount: 10)))
        try add("COMMITTED", .committed(TransferCommitted(transferID: id, savedFilename: "IMG_0001 2.jpeg", byteCount: 10)))
        try add("ERROR with transferID and message", .error(TransferErrorMessage(transferID: id, code: .hashMismatch, message: "digest mismatch")))
        try add("ERROR with transferID, no message", .error(TransferErrorMessage(transferID: id, code: .hashMismatch)))
        try add("ERROR without transferID or message", .error(TransferErrorMessage(transferID: nil, code: .authenticationFailed)))
        try add("CANCEL default reason", .cancel(TransferCancel(transferID: id)))
        try add("CANCEL timeout", .cancel(TransferCancel(transferID: id, reason: .timeout)))
        try add("PING", .ping(Ping(sequence: 1, sentAt: Fixtures.date)))
        try add("PING max sequence", .ping(Ping(sequence: .max, sentAt: Date(timeIntervalSince1970: 0))))
        try add("PONG", .pong(Ping(sequence: 1, sentAt: Fixtures.date)))

        // Every error code once.
        for code in BridgeError.Code.allCases {
            try add("ERROR code \(code.rawValue)", .error(TransferErrorMessage(transferID: nil, code: code)))
        }

        // Decoding is lenient: unknown keys ignored, key order free, lowercase UUIDs accepted.
        func decodeOnly(_ name: String, input: String) throws {
            let message = try ControlMessageCoder.decode(Data(input.utf8))
            let canonical = try ControlMessageCoder.encode(message)
            out.append([
                "name": .string(name), "kind": .string(message.kind.rawValue), "decodeOnly": true,
                "inputJson": .string(input), "json": .string(String(decoding: canonical, as: UTF8.self)), "hex": .hex(canonical),
            ])
        }
        try decodeOnly("decode: unknown keys ignored, lowercase UUID, unsorted keys", input: #"{"kind":"PROGRESS","extra":{"x":[1,2]},"body":{"transferID":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","futureField":"y","acknowledgedOffset":5}}"#)
        try decodeOnly("decode: whitespace and escaped slash", input: "{ \"body\" : { \"code\" : \"E012\", \"message\" : \"a\\/b\" } ,\n \"kind\" : \"ERROR\" }")
        try decodeOnly("decode: explicit null optional", input: #"{"body":{"code":"E005","message":null,"transferID":null},"kind":"ERROR"}"#)

        let kinds = Set(out.compactMap { c -> String? in if case .string(let k)? = c["kind"] { k } else { nil } })
        #expect(kinds == Set(ControlMessage.Kind.allCases.map(\.rawValue)), "every message kind needs a vector")
        return out
    }
}
