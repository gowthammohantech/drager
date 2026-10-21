import Foundation
public import BridgeModels
public import BridgeCore

/// User-adjustable settings shared across both apps. Secrets never live here.
public struct AppSettings: Codable, Sendable, Hashable {
    public var hasCompletedOnboarding: Bool
    public var layout: SpatialLayout
    public var gestureSensitivity: Double
    public var gestureVelocityThreshold: Double
    public var preferredPeerID: PeerID?
    /// macOS: whether to advertise the receiver service.
    public var isAvailable: Bool
    /// macOS: launch-at-login preference mirror (the source of truth is SMAppService).
    public var launchAtLoginRequested: Bool
    /// macOS: show the arrival overlay (otherwise notification only).
    public var overlayEnabled: Bool
    public var analyticsOptIn: Bool
    public var keepHistory: Bool
    public var maxFileBytes: Int64
    public var deviceDisplayNameOverride: String?

    public init(
        hasCompletedOnboarding: Bool = false,
        layout: SpatialLayout = .default,
        gestureSensitivity: Double = 1.0,
        gestureVelocityThreshold: Double = 500,
        preferredPeerID: PeerID? = nil,
        isAvailable: Bool = true,
        launchAtLoginRequested: Bool = false,
        overlayEnabled: Bool = true,
        analyticsOptIn: Bool = false,
        keepHistory: Bool = true,
        maxFileBytes: Int64 = TransferLimits.default.maxFileBytes,
        deviceDisplayNameOverride: String? = nil
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.layout = layout
        self.gestureSensitivity = gestureSensitivity
        self.gestureVelocityThreshold = gestureVelocityThreshold
        self.preferredPeerID = preferredPeerID
        self.isAvailable = isAvailable
        self.launchAtLoginRequested = launchAtLoginRequested
        self.overlayEnabled = overlayEnabled
        self.analyticsOptIn = analyticsOptIn
        self.keepHistory = keepHistory
        self.maxFileBytes = maxFileBytes
        self.deviceDisplayNameOverride = deviceDisplayNameOverride
    }

    public static let `default` = AppSettings()
}

/// `UserDefaults`-backed `KeyValueStore`. `UserDefaults` is documented thread-safe.
public final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Thread-safe in-memory `KeyValueStore` for tests and previews.
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.withLock { storage[key] = data }
    }
}

/// Observable settings container. Persists on every change.
@MainActor
@Observable
public final class SettingsStore {
    public static let storageKey = "spatialbridge.settings.v1"

    public var settings: AppSettings {
        didSet { persist() }
    }

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
        if let data = store.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            store.set(data, forKey: Self.storageKey)
        }
    }

    public func reset() {
        settings = .default
    }
}
