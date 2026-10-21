import AppKit
import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgePersistence
import BridgeSecurity
import Foundation
import Observation

/// Composition root for the Mac app.
@Observable
@MainActor
final class MacAppEnvironment {
    let identity: DeviceIdentity
    let settings: SettingsStore
    let trustedPeers: TrustedPeerStore
    let history: TransferHistoryStore
    let secrets: any SecretStore
    let pairSecrets: PairSecretStore
    let deviceInfo: DeviceInfo

    private let log = BridgeLogger(.app)

    init(
        identity: DeviceIdentity,
        settings: SettingsStore,
        trustedPeers: TrustedPeerStore,
        history: TransferHistoryStore,
        secrets: any SecretStore,
        deviceInfo: DeviceInfo
    ) {
        self.identity = identity
        self.settings = settings
        self.trustedPeers = trustedPeers
        self.history = history
        self.secrets = secrets
        self.pairSecrets = PairSecretStore(secrets: secrets)
        self.deviceInfo = deviceInfo
        DiagnosticsRecorder.shared.setAnalyticsEnabled(settings.settings.analyticsOptIn)
        log.notice("Mac environment ready; peer \(identity.peerID.shortDescription)")
    }

    static func live() -> MacAppEnvironment {
        let keychain = KeychainSecretStore()
        let secrets: any SecretStore
        let identity: DeviceIdentity
        do {
            identity = try IdentityStore(secrets: keychain).loadOrCreate()
            secrets = keychain
        } catch {
            BridgeLogger(.app).fault("Keychain unavailable (\(error)); using in-memory secrets for this launch")
            let memory = InMemorySecretStore()
            secrets = memory
            identity = (try? IdentityStore(secrets: memory).loadOrCreate()) ?? DeviceIdentity(signingKey: .init())
        }

        let settings = SettingsStore(store: UserDefaultsStore())
        let peersURL = (try? JSONFileStore<[TrustedPeer]>.applicationSupportURL(fileName: TrustedPeerStore.fileName))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(TrustedPeerStore.fileName)
        let historyURL = (try? JSONFileStore<[TransferRecord]>.applicationSupportURL(fileName: TransferHistoryStore.fileName))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(TransferHistoryStore.fileName)

        let name = settings.settings.deviceDisplayNameOverride ?? Host.current().localizedName ?? "Mac"
        let info = DeviceInfo(peerID: identity.peerID, displayName: name, platform: .macOS, model: Self.modelIdentifier())

        return MacAppEnvironment(
            identity: identity,
            settings: settings,
            trustedPeers: TrustedPeerStore(url: peersURL),
            history: TransferHistoryStore(url: historyURL),
            secrets: secrets,
            deviceInfo: info
        )
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
