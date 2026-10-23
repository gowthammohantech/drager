import CryptoKit
import Foundation
@testable import BridgeModels
@testable import BridgeSecurity

/// Fixed inputs shared by the vector generators. Nothing here is random.
enum Fixtures {
    static let transferID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
    /// 2025-10-09T08:53:20.123Z
    static let date = Date(timeIntervalSince1970: 1_760_000_000.123)

    static func identity(seed: Data) -> DeviceIdentity {
        // Any 32 bytes are a valid Ed25519 seed.
        DeviceIdentity(signingKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    static func ephemeral(_ raw: Data) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    // Long-term identities.
    static let phoneSeed = counting(from: 0x01)
    static let macSeed = counting(from: 0x41)
    static let androidSeed = counting(from: 0x81)
    static let windowsSeed = counting(from: 0xC1)

    static var phone: DeviceIdentity { identity(seed: phoneSeed) }
    static var mac: DeviceIdentity { identity(seed: macSeed) }
    static var android: DeviceIdentity { identity(seed: androidSeed) }
    static var windows: DeviceIdentity { identity(seed: windowsSeed) }

    static func device(_ identity: DeviceIdentity, _ name: String, _ platform: DevicePlatform, _ model: String) -> DeviceInfo {
        DeviceInfo(peerID: identity.peerID, displayName: name, platform: platform, model: model)
    }

    static var gesture: ExitGesture {
        ExitGesture(edge: .top, normalizedPosition: 0.42, outwardVelocity: 812.5, travelDistance: 143.25, firedAt: date)
    }
}
