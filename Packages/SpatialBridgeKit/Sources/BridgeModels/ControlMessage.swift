import Foundation

// MARK: - Control plane messages (FRD §4)

public struct Hello: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var device: DeviceInfo
    public var capabilities: [String]
    /// 32 random bytes. Bound into the pairing transcript and the session.
    public var sessionNonce: Data

    public init(
        protocolVersion: Int = BridgeProtocol.version,
        device: DeviceInfo,
        capabilities: [String] = Hello.defaultCapabilities,
        sessionNonce: Data
    ) {
        self.protocolVersion = protocolVersion
        self.device = device
        self.capabilities = capabilities
        self.sessionNonce = sessionNonce
    }

    public static let defaultCapabilities = ["transfer.v1", "gesture.v1"]
}

/// Initiator → responder. Opens an authenticated key agreement.
public struct PairRequest: Codable, Sendable, Hashable {
    /// X25519 ephemeral public key (32 bytes).
    public var ephemeralPublicKey: Data
    /// Ed25519 long-term public key (32 bytes).
    public var signingPublicKey: Data
    public var displayName: String
    /// 32 random bytes (FRD "challenge").
    public var challenge: Data

    public init(ephemeralPublicKey: Data, signingPublicKey: Data, displayName: String, challenge: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.signingPublicKey = signingPublicKey
        self.displayName = displayName
        self.challenge = challenge
    }
}

/// Responder → initiator. Completes key agreement and proves possession of the
/// responder's long-term key over the full transcript.
public struct PairResponse: Codable, Sendable, Hashable {
    public var ephemeralPublicKey: Data
    public var signingPublicKey: Data
    public var displayName: String
    public var challenge: Data
    /// Ed25519 signature over the pairing transcript.
    public var transcriptSignature: Data

    public init(
        ephemeralPublicKey: Data,
        signingPublicKey: Data,
        displayName: String,
        challenge: Data,
        transcriptSignature: Data
    ) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.signingPublicKey = signingPublicKey
        self.displayName = displayName
        self.challenge = challenge
        self.transcriptSignature = transcriptSignature
    }
}

/// Sent by *each* side after its user confirmed the short authentication string.
public struct PairConfirm: Codable, Sendable, Hashable {
    /// HMAC(confirmKey, role || peerID) — proves the sender derived the same keys.
    public var challengeResponse: Data
    /// The peer ID the sender has approved (FRD "approvedPeerKeyID").
    public var approvedPeerID: PeerID
    /// Initiator's signature over the transcript (empty for responder, who signed in PairResponse).
    public var transcriptSignature: Data

    public init(challengeResponse: Data, approvedPeerID: PeerID, transcriptSignature: Data) {
        self.challengeResponse = challengeResponse
        self.approvedPeerID = approvedPeerID
        self.transcriptSignature = transcriptSignature
    }
}

public struct PairReject: Codable, Sendable, Hashable {
    public var reason: BridgeError.Code
    public init(reason: BridgeError.Code = .pairingRejected) { self.reason = reason }
}

public struct TransferAccept: Codable, Sendable, Hashable {
    public var transferID: UUID
    /// Chunk size the receiver wants; sender must not exceed it.
    public var chunkBytes: Int
    public init(transferID: UUID, chunkBytes: Int) {
        self.transferID = transferID
        self.chunkBytes = chunkBytes
    }
}

public struct TransferReject: Codable, Sendable, Hashable {
    public var transferID: UUID
    public var reason: BridgeError.Code
    public var message: String?
    public init(transferID: UUID, reason: BridgeError.Code, message: String? = nil) {
        self.transferID = transferID
        self.reason = reason
        self.message = message
    }
}

public struct TransferProgress: Codable, Sendable, Hashable {
    public var transferID: UUID
    public var acknowledgedOffset: Int64
    public init(transferID: UUID, acknowledgedOffset: Int64) {
        self.transferID = transferID
        self.acknowledgedOffset = acknowledgedOffset
    }
}

public struct TransferComplete: Codable, Sendable, Hashable {
    public var transferID: UUID
    public var sha256Hex: String
    public var byteCount: Int64
    public init(transferID: UUID, sha256Hex: String, byteCount: Int64) {
        self.transferID = transferID
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
    }
}

public struct TransferCommitted: Codable, Sendable, Hashable {
    public var transferID: UUID
    /// The final filename as saved (may differ from the offer after collision handling).
    public var savedFilename: String
    public var byteCount: Int64
    public init(transferID: UUID, savedFilename: String, byteCount: Int64) {
        self.transferID = transferID
        self.savedFilename = savedFilename
        self.byteCount = byteCount
    }
}

public struct TransferErrorMessage: Codable, Sendable, Hashable {
    public var transferID: UUID?
    public var code: BridgeError.Code
    public var message: String?
    public init(transferID: UUID?, code: BridgeError.Code, message: String? = nil) {
        self.transferID = transferID
        self.code = code
        self.message = message
    }
}

public struct TransferCancel: Codable, Sendable, Hashable {
    public var transferID: UUID
    public var reason: BridgeError.Code
    public init(transferID: UUID, reason: BridgeError.Code = .transferCanceled) {
        self.transferID = transferID
        self.reason = reason
    }
}

/// Keepalive / RTT probe.
public struct Ping: Codable, Sendable, Hashable {
    public var sequence: UInt32
    public var sentAt: Date
    public init(sequence: UInt32, sentAt: Date = Date()) {
        self.sequence = sequence
        self.sentAt = sentAt
    }
}

/// All control messages. Encoded as JSON with a `kind` discriminator and a `body`.
public enum ControlMessage: Sendable, Hashable {
    case hello(Hello)
    case pairRequest(PairRequest)
    case pairResponse(PairResponse)
    case pairConfirm(PairConfirm)
    case pairReject(PairReject)
    case transferOffer(TransferOffer)
    case transferAccept(TransferAccept)
    case transferReject(TransferReject)
    case progress(TransferProgress)
    case complete(TransferComplete)
    case committed(TransferCommitted)
    case error(TransferErrorMessage)
    case cancel(TransferCancel)
    case ping(Ping)
    case pong(Ping)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hello = "HELLO"
        case pairRequest = "PAIR_REQUEST"
        case pairResponse = "PAIR_RESPONSE"
        case pairConfirm = "PAIR_CONFIRM"
        case pairReject = "PAIR_REJECT"
        case transferOffer = "TRANSFER_OFFER"
        case transferAccept = "TRANSFER_ACCEPT"
        case transferReject = "TRANSFER_REJECT"
        case progress = "PROGRESS"
        case complete = "COMPLETE"
        case committed = "COMMITTED"
        case error = "ERROR"
        case cancel = "CANCEL"
        case ping = "PING"
        case pong = "PONG"
    }

    public var kind: Kind {
        switch self {
        case .hello: .hello
        case .pairRequest: .pairRequest
        case .pairResponse: .pairResponse
        case .pairConfirm: .pairConfirm
        case .pairReject: .pairReject
        case .transferOffer: .transferOffer
        case .transferAccept: .transferAccept
        case .transferReject: .transferReject
        case .progress: .progress
        case .complete: .complete
        case .committed: .committed
        case .error: .error
        case .cancel: .cancel
        case .ping: .ping
        case .pong: .pong
        }
    }

    /// Transfer this message refers to, if any.
    public var transferID: UUID? {
        switch self {
        case .transferOffer(let m): m.transferID
        case .transferAccept(let m): m.transferID
        case .transferReject(let m): m.transferID
        case .progress(let m): m.transferID
        case .complete(let m): m.transferID
        case .committed(let m): m.transferID
        case .error(let m): m.transferID
        case .cancel(let m): m.transferID
        default: nil
        }
    }
}

// MARK: - Codable

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case body
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .hello: self = .hello(try container.decode(Hello.self, forKey: .body))
        case .pairRequest: self = .pairRequest(try container.decode(PairRequest.self, forKey: .body))
        case .pairResponse: self = .pairResponse(try container.decode(PairResponse.self, forKey: .body))
        case .pairConfirm: self = .pairConfirm(try container.decode(PairConfirm.self, forKey: .body))
        case .pairReject: self = .pairReject(try container.decode(PairReject.self, forKey: .body))
        case .transferOffer: self = .transferOffer(try container.decode(TransferOffer.self, forKey: .body))
        case .transferAccept: self = .transferAccept(try container.decode(TransferAccept.self, forKey: .body))
        case .transferReject: self = .transferReject(try container.decode(TransferReject.self, forKey: .body))
        case .progress: self = .progress(try container.decode(TransferProgress.self, forKey: .body))
        case .complete: self = .complete(try container.decode(TransferComplete.self, forKey: .body))
        case .committed: self = .committed(try container.decode(TransferCommitted.self, forKey: .body))
        case .error: self = .error(try container.decode(TransferErrorMessage.self, forKey: .body))
        case .cancel: self = .cancel(try container.decode(TransferCancel.self, forKey: .body))
        case .ping: self = .ping(try container.decode(Ping.self, forKey: .body))
        case .pong: self = .pong(try container.decode(Ping.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .hello(let m): try container.encode(m, forKey: .body)
        case .pairRequest(let m): try container.encode(m, forKey: .body)
        case .pairResponse(let m): try container.encode(m, forKey: .body)
        case .pairConfirm(let m): try container.encode(m, forKey: .body)
        case .pairReject(let m): try container.encode(m, forKey: .body)
        case .transferOffer(let m): try container.encode(m, forKey: .body)
        case .transferAccept(let m): try container.encode(m, forKey: .body)
        case .transferReject(let m): try container.encode(m, forKey: .body)
        case .progress(let m): try container.encode(m, forKey: .body)
        case .complete(let m): try container.encode(m, forKey: .body)
        case .committed(let m): try container.encode(m, forKey: .body)
        case .error(let m): try container.encode(m, forKey: .body)
        case .cancel(let m): try container.encode(m, forKey: .body)
        case .ping(let m): try container.encode(m, forKey: .body)
        case .pong(let m): try container.encode(m, forKey: .body)
        }
    }
}

// MARK: - Wire coding helpers

public enum ControlMessageCoder {
    /// Deterministic encoder: sorted keys, integer-millisecond dates, base64 data.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .integerMilliseconds
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .integerMilliseconds
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    public static func encode(_ message: ControlMessage) throws -> Data {
        try makeEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        try makeDecoder().decode(ControlMessage.self, from: data)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Integer milliseconds since 1970. Compact, locale-free and byte-stable across re-encoding.
    public static let integerMilliseconds = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
}

extension JSONDecoder.DateDecodingStrategy {
    public static let integerMilliseconds = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let milliseconds = try container.decode(Int64.self)
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
