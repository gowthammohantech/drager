import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import Foundation
import Observation
import UIKit

/// Pairing flow state shown by `PairingSheet`.
enum PairingUIState: Equatable {
    case idle
    case connecting(DiscoveredPeer)
    case comparing(PairingPrompt)
    case waitingForMac(PairingPrompt)
    case succeeded(TrustedPeer)
    case failed(BridgeError)

    var isActive: Bool {
        switch self {
        case .idle: false
        default: true
        }
    }
}

/// User-facing transfer phases (prompt §3 "Transfer UI").
enum TransferPhase: Equatable {
    case idle
    case preparing
    case connecting
    case transferring
    case verifying
    case completed
    case failed
    case cancelled
    case retrying(attempt: Int)

    var isActive: Bool {
        switch self {
        case .preparing, .connecting, .transferring, .verifying, .retrying: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .idle: ""
        case .preparing: "Preparing"
        case .connecting: "Connecting"
        case .transferring: "Sending"
        case .verifying: "Saving on Mac"
        case .completed: "Saved on Mac"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .retrying(let attempt): "Retrying (\(attempt))"
        }
    }
}

struct TransferUIState: Equatable {
    var phase: TransferPhase = .idle
    var filename = ""
    var bytes: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var savedName: String?
    var macName: String?
    var error: BridgeError?

    var fraction: Double { total > 0 ? min(1, Double(bytes) / Double(total)) : 0 }
}

/// App-wide observable state and actions. Views read from it and call its
/// methods; it talks to `SenderService` and the stores.
@Observable
@MainActor
final class AppModel {
    let identity: DeviceIdentity
    let device: DeviceInfo
    let settings: SettingsStore
    let sender: SenderService
    let trustedStore: TrustedPeerStore
    let historyStore: TransferHistoryStore
    let secrets: any SecretStore
    let gallery: GalleryModel

    var link = LinkStatus()
    var discovered: [DiscoveredPeer] = []
    var trustedPeers: [TrustedPeer] = []
    var history: [TransferRecord] = []
    var pairing: PairingUIState = .idle
    var transfer = TransferUIState()

    private var started = false
    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    private var pairingTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var lastRequest: (file: OutgoingFile, gesture: ExitGesture?, id: UUID)?
    private let log = BridgeLogger(.ui)
    static let automaticRetries = 2

    init(
        identity: DeviceIdentity,
        device: DeviceInfo,
        settings: SettingsStore,
        sender: SenderService,
        trustedPeers: TrustedPeerStore,
        history: TransferHistoryStore,
        secrets: any SecretStore
    ) {
        self.identity = identity
        self.device = device
        self.settings = settings
        self.sender = sender
        self.trustedStore = trustedPeers
        self.historyStore = history
        self.secrets = secrets
        self.gallery = GalleryModel(maxBytes: { [settings] in settings.settings.maxFileBytes })
        DiagnosticsRecorder.shared.setAnalyticsEnabled(settings.settings.analyticsOptIn)
    }

    var hasPairedMac: Bool { !trustedPeers.isEmpty }
    var gestureConfiguration: GestureConfiguration {
        GestureConfiguration(
            minimumOutwardVelocity: settings.settings.gestureVelocityThreshold,
            sensitivity: settings.settings.gestureSensitivity
        )
    }

    // MARK: Lifecycle

    /// Starts discovery and the connection supervisor. Called when onboarding
    /// reaches the discovery step (so the Local Network prompt appears in context) or at launch afterwards.
    func start() {
        guard !started else { return }
        started = true
        Task { await sender.start() }
        Task { [weak self] in
            guard let stream = self?.sender.status.stream() else { return }
            for await status in stream { self?.link = status }
        }
        Task { [weak self] in
            guard let stream = self?.sender.discoveredPeers else { return }
            for await peers in stream { self?.discovered = peers }
        }
        Task { await refreshStores() }
    }

    func refreshStores() async {
        trustedPeers = await trustedStore.all()
        history = settings.settings.keepHistory ? await historyStore.all() : []
    }

    func reconnect() {
        Task { await sender.reconnect() }
    }

    // MARK: Pairing (FR-107)

    func pair(with peer: DiscoveredPeer) {
        guard !pairing.isActive || pairing == .idle else { return }
        pairing = .connecting(peer)
        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let trusted = try await sender.pair(with: peer) { [weak self] prompt in
                    await self?.askUser(prompt) ?? false
                }
                settings.settings.preferredPeerID = trusted.peerID
                await refreshStores()
                pairing = .succeeded(trusted)
            } catch {
                let bridge = BridgeError.wrap(error, networkContext: true)
                pairingContinuation?.resume(returning: false)
                pairingContinuation = nil
                pairing = .failed(bridge)
            }
        }
    }

    private func askUser(_ prompt: PairingPrompt) async -> Bool {
        pairing = .comparing(prompt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pairingContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerPairing(false) }
        }
    }

    /// The user tapped "Codes match" / "Don't match".
    func answerPairing(_ approved: Bool) {
        if case .comparing(let prompt) = pairing, approved {
            pairing = .waitingForMac(prompt)
        }
        pairingContinuation?.resume(returning: approved)
        pairingContinuation = nil
    }

    func cancelPairing() {
        answerPairing(false)
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    func dismissPairing() {
        switch pairing {
        case .succeeded, .failed: pairing = .idle
        default: break
        }
    }

    func unpair(_ peer: TrustedPeer) {
        Task {
            do {
                try await sender.unpair(peer.peerID)
                if settings.settings.preferredPeerID == peer.peerID { settings.settings.preferredPeerID = nil }
            } catch {
                log.error("Unpair failed: \(error)")
            }
            await refreshStores()
        }
    }

    func setPreferred(_ peer: TrustedPeer) {
        settings.settings.preferredPeerID = peer.peerID
        reconnect()
    }

    // MARK: Transfers (FR-105, FR-106, FR-108)

    /// Starts one transfer for one gesture or Send tap. Ignored while a transfer is active,
    /// so a single activation can never start two transfers (FR-108).
    func send(_ item: StagedItem, gesture: ExitGesture?) {
        guard !transfer.phase.isActive, let file = item.outgoing else { return }
        let request = (file: file, gesture: gesture, id: UUID())
        lastRequest = request
        transferTask = Task { await run(request, attempt: 0) }
    }

    func retry() {
        guard !transfer.phase.isActive, let request = lastRequest else { return }
        // Same transfer ID: if the Mac already saved it, it answers COMMITTED instead of saving twice.
        transferTask = Task { await run(request, attempt: 0) }
    }

    func cancelTransfer() {
        transferTask?.cancel()
    }

    func dismissTransfer() {
        guard !transfer.phase.isActive else { return }
        transfer = TransferUIState()
    }

    private func run(_ request: (file: OutgoingFile, gesture: ExitGesture?, id: UUID), attempt: Int) async {
        transfer = TransferUIState(phase: attempt == 0 ? .preparing : .retrying(attempt: attempt), filename: request.file.filename, macName: link.peer?.displayName)
        if !link.isConnected {
            transfer.phase = attempt == 0 ? .connecting : .retrying(attempt: attempt)
            await sender.reconnect()
            guard await waitForConnection(timeout: .seconds(12)) else {
                if Task.isCancelled { return finish(.cancelled, error: BridgeError(.transferCanceled)) }
                return finish(.failed, error: BridgeError(link.peer == nil ? .noPeer : (link.lastError ?? .peerLost)))
            }
        }
        transfer.macName = link.peer?.displayName
        do {
            let committed = try await sender.send(request.file, gesture: request.gesture, transferID: request.id) { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            }
            transfer.savedName = committed.savedFilename
            transfer.bytes = transfer.total
            finish(.completed, error: nil)
            UIAccessibility.post(notification: .announcement, argument: "Saved on \(transfer.macName ?? "Mac")")
        } catch {
            let bridge = BridgeError.wrap(error, networkContext: true)
            if bridge.code == .transferCanceled || Task.isCancelled {
                return finish(.cancelled, error: bridge)
            }
            if bridge.isRetryable, attempt < Self.automaticRetries {
                transfer.phase = .retrying(attempt: attempt + 1)
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return finish(.cancelled, error: BridgeError(.transferCanceled)) }
                return await run(request, attempt: attempt + 1)
            }
            finish(.failed, error: bridge)
        }
    }

    private func apply(_ snapshot: TransferProgressSnapshot) {
        guard transfer.phase.isActive else { return }
        if snapshot.totalBytes > 0 { transfer.total = snapshot.totalBytes }
        transfer.bytes = max(transfer.bytes, snapshot.bytesTransferred)
        transfer.bytesPerSecond = snapshot.bytesPerSecond
        switch snapshot.state {
        case .created: transfer.phase = .preparing
        case .offered, .accepted, .streaming: transfer.phase = .transferring
        case .verifying: transfer.phase = .verifying
        default: break
        }
    }

    private func finish(_ phase: TransferPhase, error: BridgeError?) {
        transfer.phase = phase
        transfer.error = error
        transferTask = nil
        Task { await refreshStores() }
    }

    private func waitForConnection(timeout: Duration) async -> Bool {
        if link.isConnected { return true }
        let stream = sender.status.stream()
        return (try? await withBridgeTimeout(timeout) {
            for await status in stream where status.isConnected { return true }
            return false
        }) ?? false
    }

    // MARK: Settings actions

    func clearHistory() {
        Task {
            try? await historyStore.clear()
            await refreshStores()
        }
    }

    func setAnalytics(_ enabled: Bool) {
        settings.settings.analyticsOptIn = enabled
        DiagnosticsRecorder.shared.setAnalyticsEnabled(enabled)
    }

    /// Writes a scrubbed diagnostics bundle and returns its URL for sharing.
    func exportDiagnostics() -> URL? {
        let environment = DiagnosticBundle.Environment(
            appVersion: appVersion, build: buildNumber, platform: .iOS,
            osVersion: UIDevice.current.systemVersion, deviceModel: device.model
        )
        return try? DiagnosticBundleExporter.writeTemporaryFile(DiagnosticBundleExporter.makeBundle(environment: environment))
    }

    /// Unpairs everything, wipes the identity and settings (Settings › Reset).
    func resetEverything() {
        Task {
            for peer in trustedPeers { try? await sender.unpair(peer.peerID) }
            try? await historyStore.clear()
            settings.reset()
            gallery.removeAll()
            await refreshStores()
        }
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
