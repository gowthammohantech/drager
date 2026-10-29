import AppKit
import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgeNetworking
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import CryptoKit
import Foundation
import Observation
import QuickLookThumbnailing
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

/// Composition root for the Mac app. `-ui-testing` gives isolated state and no advertising.
@MainActor
enum MacAppEnvironment {
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }

    static func live() -> MacAppModel {
        let uiTesting = isUITesting
        let keychain = KeychainSecretStore(service: "com.gowthammohan.drager.mac")
        let secrets: any SecretStore
        let identity: DeviceIdentity
        if uiTesting {
            let memory = InMemorySecretStore()
            secrets = memory
            identity = (try? IdentityStore(secrets: memory).loadOrCreate()) ?? DeviceIdentity(signingKey: .init())
        } else {
            do {
                identity = try IdentityStore(secrets: keychain).loadOrCreate()
                secrets = keychain
            } catch {
                BridgeLogger(.app).fault("Keychain unavailable (\(error)); using in-memory secrets for this launch")
                let memory = InMemorySecretStore()
                secrets = memory
                identity = (try? IdentityStore(secrets: memory).loadOrCreate()) ?? DeviceIdentity(signingKey: .init())
            }
        }
        let defaults = uiTesting ? (UserDefaults(suiteName: "uitest-\(UUID().uuidString)") ?? .standard) : .standard
        let settings = SettingsStore(store: UserDefaultsStore(defaults: defaults))
        let root = uiTesting ? FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)", isDirectory: true) : nil
        func url(_ name: String) -> URL {
            if let root { return root.appendingPathComponent(name) }
            return (try? JSONFileStore<[TransferRecord]>.applicationSupportURL(fileName: name))
                ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
        }
        let trusted = TrustedPeerStore(url: url(TrustedPeerStore.fileName))
        let history = TransferHistoryStore(url: url(TransferHistoryStore.fileName))
        let destination = BookmarkedFolderStore(defaults: defaults)
        let name = settings.settings.deviceDisplayNameOverride ?? Host.current().localizedName ?? "Mac"
        let device = DeviceInfo(peerID: identity.peerID, displayName: name, platform: .macOS, model: modelIdentifier())
        let staging = (try? StagingArea.appDefault()) ?? (try! StagingArea(directory: FileManager.default.temporaryDirectory))

        let service = ReceiverService(dependencies: .init(
            identity: identity,
            device: device,
            pairSecrets: PairSecretStore(secrets: secrets),
            trustedPeers: trusted,
            history: history,
            staging: staging,
            destination: destination,
            policy: TransferPolicy(limits: TransferLimits(maxFileBytes: settings.settings.maxFileBytes))
        ))
        return MacAppModel(identity: identity, device: device, settings: settings, service: service,
                           trustedStore: trusted, historyStore: history, destination: destination, advertise: !uiTesting)
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Mac app state and actions.
@Observable
@MainActor
final class MacAppModel {
    let identity: DeviceIdentity
    let device: DeviceInfo
    let settings: SettingsStore
    let service: ReceiverService
    let trustedStore: TrustedPeerStore
    let historyStore: TransferHistoryStore
    let destination: BookmarkedFolderStore
    @ObservationIgnored let overlay = ArrivalOverlayController()
    private let advertise: Bool

    var connectedPeers: [TrustedPeer] = []
    var trustedPeers: [TrustedPeer] = []
    var history: [TransferRecord] = []
    var destinationPath: String?
    var destinationProblem: BridgeError?
    var advertiserState: ServiceAdvertiser.State = .stopped
    var pendingPairing: PairingPrompt?
    var lastPairingResult: String?
    var activeTransfer: (filename: String, fraction: Double)?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    private var started = false
    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var pairingWindowStorage: PairingWindowController?
    @ObservationIgnored private let notifier = Notifier()
    private var pairingWindow: PairingWindowController {
        if let pairingWindowStorage { return pairingWindowStorage }
        let controller = PairingWindowController(model: self)
        pairingWindowStorage = controller
        return controller
    }
    private let log = BridgeLogger(.app)

    init(identity: DeviceIdentity, device: DeviceInfo, settings: SettingsStore, service: ReceiverService,
         trustedStore: TrustedPeerStore, historyStore: TransferHistoryStore, destination: BookmarkedFolderStore, advertise: Bool) {
        self.identity = identity
        self.device = device
        self.settings = settings
        self.service = service
        self.trustedStore = trustedStore
        self.historyStore = historyStore
        self.destination = destination
        self.advertise = advertise
        DiagnosticsRecorder.shared.setAnalyticsEnabled(settings.settings.analyticsOptIn)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        notifier.onReveal = { [weak self] path in self?.destination.reveal(path: path) }
        notifier.requestAuthorization()
        refreshDestination()
        Task {
            // The model lives for the whole process, so a strong capture is fine.
            await service.setPairingDecisionHandler { prompt in
                await self.askUser(prompt)
            }
            if advertise {
                await service.start(available: settings.settings.isAvailable, allowPairing: settings.settings.allowNewPairings)
            }
        }
        observe(service.events.stream()) { model, event in model.handle(event) }
        observe(service.connectedPeers.stream()) { model, peers in model.connectedPeers = peers }
        observe(service.advertiser.state) { model, state in model.advertiserState = state }
        observe(service.pairingActivity.stream()) { model, activity in model.handle(activity) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        Task { await refreshStores() }
    }

    private func observe<Element: Sendable>(_ stream: AsyncStream<Element>, _ apply: @escaping @MainActor (MacAppModel, Element) -> Void) {
        Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                apply(self, element)
            }
        }
    }

    func refreshStores() async {
        trustedPeers = await trustedStore.all()
        history = settings.settings.keepHistory ? await historyStore.all() : []
    }

    // MARK: Receiving

    private func handle(_ event: ReceiverEvent) {
        switch event {
        case .accepted(let offer, _):
            activeTransfer = (offer.filename, 0)
            if settings.settings.overlayEnabled {
                if !overlay.showIncoming(offer: offer, layout: settings.settings.layout) {
                    log.notice("Overlay unavailable; notification fallback")
                }
            }
        case .progress(let id, let received, let total):
            let fraction = total > 0 ? Double(received) / Double(total) : 0
            activeTransfer?.fraction = fraction
            overlay.showProgress(transferID: id, fraction: fraction)
        case .verifying(let id):
            overlay.showVerifying(transferID: id)
        case .committed(let offer, let url, let peer):
            activeTransfer = nil
            destinationProblem = nil
            let thumbnail = thumbnail(for: url)
            overlay.showSaved(transferID: offer.transferID, savedName: url.lastPathComponent, thumbnail: thumbnail)
            if !settings.settings.overlayEnabled || NSScreen.screens.isEmpty {
                notifier.post(title: "Received from \(peer.displayName)", body: url.lastPathComponent, revealPath: url.path)
            }
            Task { try? await Task.sleep(for: .milliseconds(200)); await refreshStores() }
        case .failed(let offer, let reason, let peer):
            activeTransfer = nil
            overlay.showFailed(transferID: offer.transferID, code: reason.code)
            if reason.code != .transferCanceled {
                notifier.post(title: "Transfer from \(peer.displayName) failed", body: reason.code.userMessage, revealPath: nil)
            }
            if reason.code == .destinationPermissionExpired { destinationProblem = reason }
            Task { await refreshStores() }
        case .replayed:
            // The sender retried an ID that is already saved; it got COMMITTED
            // again. The first commit already showed success, so stay quiet.
            break
        case .rejected(_, let reason, let peer):
            if reason.code == .destinationPermissionExpired || reason.code == .insufficientStorage {
                destinationProblem = reason
                notifier.post(title: "Couldn't receive from \(peer.displayName)", body: reason.code.recoverySuggestion, revealPath: nil)
            }
            Task { await refreshStores() }
        }
    }

    private func thumbnail(for url: URL) -> NSImage? {
        try? destination.withAccess { _ in
            guard let image = NSImage(contentsOf: url) else { return NSWorkspace.shared.icon(forFile: url.path) }
            return image
        }
    }

    private func screensChanged() {
        // FR-205: fall back to the main display when the chosen one disappears.
        if let id = settings.settings.layout.macDisplayIdentifier,
           !ArrivalOverlayController.displays().contains(where: { $0.identifier == id }) {
            log.notice("Chosen display disconnected; using main display")
        }
    }

    // MARK: Pairing

    private func askUser(_ prompt: PairingPrompt) async -> Bool {
        pendingPairing = prompt
        pairingWindow.show()
        notifier.post(title: "Pair with \(prompt.peer.displayName)?", body: "Compare the code \(prompt.formattedCode) on both devices.", revealPath: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in pairingContinuation = continuation }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerPairing(false) }
        }
    }

    func answerPairing(_ approved: Bool) {
        pairingContinuation?.resume(returning: approved)
        pairingContinuation = nil
        pendingPairing = nil
        if !approved { pairingWindow.close() }
    }

    private func handle(_ activity: PairingActivity) {
        switch activity {
        case .succeeded(let peer):
            lastPairingResult = "Paired with \(peer.displayName)"
        case .failed(let error):
            lastPairingResult = error.code == .pairingRejected ? "Pairing declined" : error.code.userMessage
        }
        pendingPairing = nil
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
        Task {
            await refreshStores()
            try? await Task.sleep(for: .seconds(2))
            pairingWindow.close()
            lastPairingResult = nil
        }
    }

    func unpair(_ peer: TrustedPeer) {
        Task {
            try? await service.unpair(peer.peerID)
            await refreshStores()
        }
    }

    // MARK: Preferences

    func setAvailable(_ available: Bool) {
        settings.settings.isAvailable = available
        Task { await service.setAvailable(available) }
    }

    func setAllowPairing(_ allow: Bool) {
        settings.settings.allowNewPairings = allow
        Task { await service.setAllowPairing(allow) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Drager saves files from your phone."
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try destination.setFolder(url)
            destinationProblem = nil
        } catch {
            destinationProblem = BridgeError(.destinationPermissionExpired, detail: "bookmark failed")
        }
        refreshDestination()
    }

    func refreshDestination() {
        do {
            let url = try destination.resolve()
            destinationPath = url.path(percentEncoded: false)
        } catch {
            destinationPath = nil
            if destination.hasBookmark { destinationProblem = BridgeError.wrap(error, networkContext: false) }
        }
    }

    func revealDestination() {
        guard let destinationPath else { return }
        destination.reveal(path: destinationPath)
    }

    func reveal(_ record: TransferRecord) {
        guard let path = record.savedPath else { return }
        destination.reveal(path: path)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Login item change failed: \(error.localizedDescription)")
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
        settings.settings.launchAtLoginRequested = enabled
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setDisplay(_ identifier: String?) {
        settings.settings.layout.macDisplayIdentifier = identifier
    }

    func testOverlay() {
        overlay.test(layout: settings.settings.layout, edge: .top)
    }

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

    func exportDiagnostics() {
        let environment = DiagnosticBundle.Environment(
            appVersion: appVersion, build: buildNumber, platform: .macOS,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, deviceModel: device.model
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SpatialBridge-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? DiagnosticBundleExporter.encode(DiagnosticBundleExporter.makeBundle(environment: environment)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    var statusSummary: String {
        if !settings.settings.isAvailable { return "Not available" }
        if destinationPath == nil { return "Choose a destination folder" }
        if let activeTransfer { return "Receiving \(activeTransfer.filename)…" }
        switch advertiserState {
        case .failed(.localNetworkDenied): return "Local Network access denied"
        case .failed: return "Network unavailable"
        case .stopped: return "Starting…"
        case .advertising:
            return connectedPeers.isEmpty ? "Waiting for phone" : "Connected to \(connectedPeers.map(\.displayName).joined(separator: ", "))"
        }
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}

/// Local notifications: completion fallback (FR-210) and pairing requests.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onReveal: ((String) -> Void)?

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, revealPath: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let revealPath { content.userInfo = ["path": revealPath] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run { onReveal?(path) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
