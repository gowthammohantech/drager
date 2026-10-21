import Foundation
public import BridgeCore
public import BridgeModels
public import BridgeSecurity
import os

/// A device identity plus its HELLO description, for tests.
public struct TestPeer: Sendable {
    public let identity: DeviceIdentity
    public let device: DeviceInfo
    public let secrets: InMemorySecretStore

    public init(name: String, platform: DevicePlatform) {
        let secrets = InMemorySecretStore()
        // In-memory stores never throw.
        let identity = try! IdentityStore(secrets: secrets).loadOrCreate()
        self.identity = identity
        self.secrets = secrets
        self.device = DeviceInfo(peerID: identity.peerID, displayName: name, platform: platform, model: platform == .iOS ? "iPhone18,2" : "Mac16,1")
    }

    public static func iPhone(_ name: String = "Test iPhone") -> TestPeer { TestPeer(name: name, platform: .iOS) }
    public static func mac(_ name: String = "Test Mac") -> TestPeer { TestPeer(name: name, platform: .macOS) }

    public var asTrusted: TrustedPeer {
        TrustedPeer(peerID: device.peerID, displayName: device.displayName, platform: device.platform, model: device.model, signingPublicKey: identity.publicKeyData)
    }
}

/// Mutable in-memory `TrustDirectory`.
public final class InMemoryTrustDirectory: TrustDirectory, Sendable {
    private let peers: OSAllocatedUnfairLock<[PeerID: TrustedPeer]>

    public init(_ peers: [TrustedPeer] = []) {
        self.peers = OSAllocatedUnfairLock(initialState: Dictionary(uniqueKeysWithValues: peers.map { ($0.peerID, $0) }))
    }

    public func trustedPeer(_ id: PeerID) async -> TrustedPeer? { peers.withLock { $0[id] } }
    public func allTrusted() async -> [TrustedPeer] { peers.withLock { Array($0.values) } }
    public func add(_ peer: TrustedPeer) { peers.withLock { $0[peer.peerID] = peer } }
    public func remove(_ id: PeerID) { peers.withLock { _ = $0.removeValue(forKey: id) } }
}

/// Records pairing prompts and answers with a fixed decision, optionally after a delay.
public final class ScriptedDecision: Sendable {
    private let prompts = OSAllocatedUnfairLock<[PairingPrompt]>(initialState: [])
    public let approve: Bool
    public let delay: Duration?

    public init(approve: Bool, delay: Duration? = nil) {
        self.approve = approve
        self.delay = delay
    }

    public var recordedPrompts: [PairingPrompt] { prompts.withLock { $0 } }

    public var handler: PairingDecisionHandler {
        { [self] prompt in
            prompts.withLock { $0.append(prompt) }
            if let delay { try? await Task.sleep(for: delay) }
            return approve
        }
    }
}
