import Foundation

/// Stable identifier of a device, derived from the fingerprint of its long-term
/// signing public key. It is public information and safe to log at `.public`
/// only in truncated form; use `shortDescription` for logs.
public struct PeerID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init?(validating rawValue: String) {
        // 32 lowercase hex chars (128-bit fingerprint prefix).
        guard rawValue.count == 32, rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// First 8 characters, suitable for user-facing fingerprints and logs.
    public var shortDescription: String { String(rawValue.prefix(8)) }
}

public enum DevicePlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case iOS
    case macOS
}

/// Human-readable device description exchanged in HELLO. Never authenticated on
/// its own; identity comes from `PeerID`/keys.
public struct DeviceInfo: Codable, Sendable, Hashable {
    public var peerID: PeerID
    public var displayName: String
    public var platform: DevicePlatform
    public var model: String

    public init(peerID: PeerID, displayName: String, platform: DevicePlatform, model: String) {
        self.peerID = peerID
        self.displayName = String(displayName.prefix(64))
        self.platform = platform
        self.model = String(model.prefix(64))
    }
}

/// A peer that has been discovered on the local network but not necessarily trusted.
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    /// Bonjour service name (unique per advertised service instance).
    public var id: String
    public var serviceName: String
    /// Peer ID if the TXT record advertised one; `nil` for legacy/unknown peers.
    public var advertisedPeerID: PeerID?
    public var advertisedDisplayName: String?
    public var platform: DevicePlatform?
    public var protocolVersion: Int?
    public var discoveredAt: Date

    public init(
        serviceName: String,
        advertisedPeerID: PeerID?,
        advertisedDisplayName: String?,
        platform: DevicePlatform?,
        protocolVersion: Int?,
        discoveredAt: Date = Date()
    ) {
        self.id = serviceName
        self.serviceName = serviceName
        self.advertisedPeerID = advertisedPeerID
        self.advertisedDisplayName = advertisedDisplayName
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.discoveredAt = discoveredAt
    }

    public var isCompatible: Bool {
        guard let protocolVersion else { return true }
        return protocolVersion == BridgeProtocol.version
    }
}

/// A peer the user has explicitly approved. Secrets (PSK) live in the secret
/// store keyed by `peerID`; this record is public metadata only.
public struct TrustedPeer: Identifiable, Codable, Hashable, Sendable {
    public var id: PeerID { peerID }
    public var peerID: PeerID
    public var displayName: String
    public var platform: DevicePlatform
    public var model: String
    /// Raw Ed25519 public key (32 bytes).
    public var signingPublicKey: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    public var lastServiceName: String?

    public init(
        peerID: PeerID,
        displayName: String,
        platform: DevicePlatform,
        model: String,
        signingPublicKey: Data,
        pairedAt: Date = Date(),
        lastSeenAt: Date? = nil,
        lastServiceName: String? = nil
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.platform = platform
        self.model = model
        self.signingPublicKey = signingPublicKey
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.lastServiceName = lastServiceName
    }
}

/// Peer connection state machine (FRD §1).
public enum PeerConnectionState: Sendable, Hashable {
    case idle
    case permissionPending
    case discovering
    case pairing
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case disconnected(reason: BridgeError.Code?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .permissionPending: "Waiting for permission"
        case .discovering: "Looking for Macs"
        case .pairing: "Pairing"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting (\(attempt))"
        case .disconnected: "Disconnected"
        }
    }
}

/// Coarse link quality derived from round-trip-time measurements.
public enum ConnectionQuality: String, Sendable, Hashable, Codable {
    case unknown
    case poor
    case fair
    case good
    case excellent

    /// Classify from a smoothed round-trip time in seconds.
    public init(roundTripTime rtt: TimeInterval?) {
        guard let rtt else { self = .unknown; return }
        switch rtt {
        case ..<0.015: self = .excellent
        case ..<0.040: self = .good
        case ..<0.120: self = .fair
        default: self = .poor
        }
    }
}
