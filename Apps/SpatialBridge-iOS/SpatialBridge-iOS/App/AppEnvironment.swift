import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgePersistence
import BridgeSecurity
import Foundation
import Observation
import UIKit

/// Composition root. Everything the UI needs is constructed here once and
/// injected through the SwiftUI environment, so screens stay testable.
@Observable
@MainActor
final class AppEnvironment {
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
        log.notice("App environment ready; peer \(identity.peerID.shortDescription)")
    }

    /// Production wiring. Falls back to an in-memory secret store only if the
    /// Keychain is unavailable (for example an unsigned simulator build), and
    /// logs that fact so it is never silent.
    static func live() -> AppEnvironment {
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

        let name = settings.settings.deviceDisplayNameOverride ?? UIDevice.current.name
        let info = DeviceInfo(peerID: identity.peerID, displayName: name, platform: .iOS, model: Self.modelIdentifier())

        return AppEnvironment(
            identity: identity,
            settings: settings,
            trustedPeers: TrustedPeerStore(url: peersURL),
            history: TransferHistoryStore(url: historyURL),
            secrets: secrets,
            deviceInfo: info
        )
    }

    static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
