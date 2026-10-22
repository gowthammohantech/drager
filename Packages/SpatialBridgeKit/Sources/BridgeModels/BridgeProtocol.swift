import Foundation

/// Protocol-wide constants. Numbers are configuration defaults from the FRD, not OS guarantees.
public enum BridgeProtocol {
    /// Wire protocol version. Bump on any incompatible change to frames or messages.
    public static let version = 1

    /// Bonjour service type advertised by receivers and browsed by senders.
    public static let serviceType = "_spatialbridge._tcp"
    public static let serviceDomain = "local."

    /// TXT record keys advertised with the Bonjour service.
    public enum TXTKey {
        public static let peerID = "pid"
        public static let displayName = "name"
        public static let platform = "plat"
        public static let protocolVersion = "pv"
        public static let role = "role"
    }

    /// Keychain / secret-store key prefixes.
    public enum SecretKey {
        public static let identitySeed = "identity.ed25519.seed"
        public static let pairPSKPrefix = "pair.psk."

        public static func pairPSK(for peer: PeerID) -> String { pairPSKPrefix + peer.rawValue }
    }
}

/// Tunable limits for frames and transfers. Defaults follow FRD §4.
public struct TransferLimits: Codable, Sendable, Hashable {
    /// Maximum encoded control message size.
    public var maxControlFrameBytes: Int
    /// Preferred chunk payload size for file streaming.
    public var chunkBytes: Int
    /// Maximum chunk payload accepted from a peer (allows the peer a little slack).
    public var maxChunkBytes: Int
    /// Maximum file size accepted in this build.
    public var maxFileBytes: Int64
    /// Number of chunk sends allowed in flight before the sender waits.
    public var sendWindow: Int
    /// Handshake / pairing timeout.
    public var handshakeTimeout: Duration
    /// Idle timeout for an in-progress transfer with no bytes flowing.
    public var transferIdleTimeout: Duration
    /// Free-space headroom required beyond the file size.
    public var diskHeadroomBytes: Int64
    /// How long partial staging files are retained before cleanup.
    public var stagingRetention: Duration

    public init(
        maxControlFrameBytes: Int = 64 * 1024,
        chunkBytes: Int = 256 * 1024,
        maxChunkBytes: Int = 512 * 1024,
        maxFileBytes: Int64 = 100 * 1024 * 1024,
        sendWindow: Int = 4,
        handshakeTimeout: Duration = .seconds(30),
        transferIdleTimeout: Duration = .seconds(30),
        diskHeadroomBytes: Int64 = 64 * 1024 * 1024,
        stagingRetention: Duration = .seconds(24 * 60 * 60)
    ) {
        self.maxControlFrameBytes = maxControlFrameBytes
        self.chunkBytes = chunkBytes
        self.maxChunkBytes = maxChunkBytes
        self.maxFileBytes = maxFileBytes
        self.sendWindow = sendWindow
        self.handshakeTimeout = handshakeTimeout
        self.transferIdleTimeout = transferIdleTimeout
        self.diskHeadroomBytes = diskHeadroomBytes
        self.stagingRetention = stagingRetention
    }

    public static let `default` = TransferLimits()
}

extension Duration {
    /// Seconds as a `TimeInterval`, for APIs that still take `TimeInterval`.
    public var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
