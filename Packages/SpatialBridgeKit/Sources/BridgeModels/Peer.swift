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

/// Operating system a device runs, as sent in HELLO and the `plat` TXT key.
///
/// An open string value (ADR-015): values this build doesn't know decode and
/// re-encode unchanged, so a HELLO from a newer platform never fails to decode.
/// On the wire it is a plain JSON string.
public struct DevicePlatform: RawRepresentable, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let iOS = DevicePlatform(rawValue: "iOS")
    public static let macOS = DevicePlatform(rawValue: "macOS")
    public static let android = DevicePlatform(rawValue: "android")
    public static let windows = DevicePlatform(rawValue: "windows")

    /// The values this build knows. Other values are still valid.
    public static let allCases: [DevicePlatform] = [.iOS, .macOS, .android, .windows]

    /// `true` for one of `allCases`.
    public var isKnown: Bool { Self.allCases.contains(self) }

    /// Phones and tablets, as opposed to computers. `nil` when unknown.
    public var isHandheld: Bool? {
        switch self {
        case .iOS, .android: true
        case .macOS, .windows: false
        default: nil
        }
    }

    public var description: String { rawValue }

    /// Name for UI copy: "iPhone", "Mac", "Android phone", "Windows PC".
    /// Unknown platforms fall back to "device".
    public var displayName: String {
        switch self {
        case .iOS: "iPhone"
        case .macOS: "Mac"
        case .android: "Android phone"
        case .windows: "Windows PC"
        default: "device"
        }
    }

    /// Generic noun for UI copy when the brand doesn't matter: "phone",
    /// "computer", or "device" when unknown.
    public var genericNoun: String {
        switch isHandheld {
        case true?: "phone"
        case false?: "computer"
        case nil: "device"
        }
    }

    /// SF Symbol name for the platform's icon. A plain string, so this module stays UI-free.
    public var symbolName: String {
        switch self {
        case .iOS: "iphone"
        case .macOS: "laptopcomputer"
        case .android: "smartphone"
        case .windows: "pc"
        default: "questionmark"
        }
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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

/// What an advertised Bonjour service instance is for. A Mac advertises a
/// `session` instance (TLS-PSK, trusted peers only) and, while pairing is
/// allowed, a separate `pairing` instance (plain TCP, pairing handshake only).
public enum ServiceRole: String, Codable, Sendable, Hashable, CaseIterable {
    case session
    case pairing
}

/// A peer that has been discovered on the local network but not necessarily trusted.
/// One device may advertise several service instances; discovery merges them
/// into a single `DiscoveredPeer` keyed by the advertised peer ID.
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    /// Advertised peer ID when present, otherwise the Bonjour service name.
    public var id: String
    /// Bonjour service name of the primary instance (session if available).
    public var serviceName: String
    /// Roles this device currently advertises.
    public var roles: Set<ServiceRole>
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
        roles: Set<ServiceRole> = [.session],
        discoveredAt: Date = Date()
    ) {
        self.id = advertisedPeerID?.rawValue ?? serviceName
        self.serviceName = serviceName
        self.roles = roles
        self.advertisedPeerID = advertisedPeerID
        self.advertisedDisplayName = advertisedDisplayName
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.discoveredAt = discoveredAt
    }

    public var acceptsPairing: Bool { roles.contains(.pairing) }
    public var acceptsSessions: Bool { roles.contains(.session) }

    /// Best name to show the user.
    public var displayName: String { advertisedDisplayName ?? serviceName }

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
        case .discovering: "Looking for computers"
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
