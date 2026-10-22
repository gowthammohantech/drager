import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgeNetworking
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import CryptoKit
import Foundation
import Network
import Observation
import UIKit

/// Composition root. Builds every dependency once and hands the UI a single
/// `AppModel`. UI tests launch with `-ui-testing` to get isolated, in-memory
/// state that never touches the network.
@MainActor
enum AppEnvironment {
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }

    static func live() -> AppModel {
        let uiTesting = isUITesting
        let secrets: any SecretStore
        let identity: DeviceIdentity
        let keychain = KeychainSecretStore(service: "com.gowthammohan.spatialbridge.ios")
        if uiTesting {
            let memory = InMemorySecretStore()
            secrets = memory
            identity = (try? IdentityStore(secrets: memory).loadOrCreate()) ?? DeviceIdentity(signingKey: .init())
        } else {
            do {
                identity = try IdentityStore(secrets: keychain).loadOrCreate()
                secrets = keychain
            } catch {
                // Never silent: an unsigned simulator build may lack Keychain access.
                BridgeLogger(.app).fault("Keychain unavailable (\(error)); using in-memory secrets for this launch")
                let memory = InMemorySecretStore()
                secrets = memory
                identity = (try? IdentityStore(secrets: memory).loadOrCreate()) ?? DeviceIdentity(signingKey: .init())
            }
        }

        let defaults = uiTesting ? (UserDefaults(suiteName: "uitest-\(UUID().uuidString)") ?? .standard) : .standard
        let settings = SettingsStore(store: UserDefaultsStore(defaults: defaults))
        if ProcessInfo.processInfo.arguments.contains("-skip-onboarding") {
            settings.settings.hasCompletedOnboarding = true
        }
        let storageRoot = uiTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)", isDirectory: true)
            : nil
        let trusted = TrustedPeerStore(url: storeURL(TrustedPeerStore.fileName, root: storageRoot))
        let history = TransferHistoryStore(url: storeURL(TransferHistoryStore.fileName, root: storageRoot))

        let name = settings.settings.deviceDisplayNameOverride ?? UIDevice.current.name
        let device = DeviceInfo(peerID: identity.peerID, displayName: name, platform: .iOS, model: modelIdentifier())
        let locator: any PeerLocating = uiTesting ? OfflineLocator() : BonjourBrowser(excluding: identity.peerID)

        let service = SenderService(dependencies: .init(
            identity: identity,
            device: device,
            pairSecrets: PairSecretStore(secrets: secrets),
            trustedPeers: trusted,
            history: history,
            locator: locator,
            limits: TransferLimits(maxFileBytes: settings.settings.maxFileBytes),
            preferredPeerID: { await MainActor.run { settings.settings.preferredPeerID } },
            watchNetworkPath: !uiTesting
        ))

        OutgoingStaging.purge()
        return AppModel(
            identity: identity,
            device: device,
            settings: settings,
            sender: service,
            trustedPeers: trusted,
            history: history,
            secrets: secrets
        )
    }

    private static func storeURL(_ name: String, root: URL?) -> URL {
        if let root { return root.appendingPathComponent(name) }
        return (try? JSONFileStore<[TransferRecord]>.applicationSupportURL(fileName: name))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Locator used by UI tests: never finds anything, never touches the network.
final class OfflineLocator: PeerLocating, @unchecked Sendable {
    private let peerBroadcaster = Broadcaster<[DiscoveredPeer]>([])
    private let stateBroadcaster = Broadcaster<DiscoveryState>(.idle)
    nonisolated var peers: AsyncStream<[DiscoveredPeer]> { peerBroadcaster.stream() }
    nonisolated var state: AsyncStream<DiscoveryState> { stateBroadcaster.stream() }
    nonisolated var currentPeers: [DiscoveredPeer] { [] }
    nonisolated func endpoint(for peerID: String, role: ServiceRole) -> NWEndpoint? { nil }
    nonisolated func start() async { stateBroadcaster.send(.waiting(.noPeer)) }
    nonisolated func stop() async { stateBroadcaster.send(.idle) }
    nonisolated func restart() async {}
}
