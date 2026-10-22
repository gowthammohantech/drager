import Foundation
public import BridgeModels

// MARK: - Time

/// Injectable clock so timeouts and timestamps are deterministic in tests.
public protocol BridgeClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: BridgeClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Secrets

/// Keychain-like storage for small secrets. Implementations must never log values.
public protocol SecretStore: Sendable {
    func read(key: String) throws -> Data?
    func write(_ value: Data, key: String) throws
    func delete(key: String) throws
    /// Keys beginning with `prefix`.
    func keys(withPrefix prefix: String) throws -> [String]
}

// MARK: - Transport

/// A bidirectional, ordered, authenticated stream of frames. Implemented over
/// Network.framework in `BridgeNetworking` and in memory in `BridgeTestSupport`.
public protocol FrameTransport: AnyObject, Sendable {
    /// Frames from the peer, in order. Finishes when the peer closes; throws on failure.
    var incomingFrames: AsyncThrowingStream<Frame, any Error> { get }
    /// Sends one frame. Returns once the transport has accepted the bytes (backpressure point).
    func send(_ frame: Frame) async throws
    /// Closes the transport. Idempotent.
    func close() async
}

extension FrameTransport {
    public func send(_ message: ControlMessage) async throws {
        try await send(.control(try ControlMessageCoder.encode(message)))
    }
}

// MARK: - Storage

/// Where received files are finally stored (FRD FR-206…FR-209).
public protocol DestinationStore: Sendable {
    /// Human-readable description of the destination for UI (never a secret).
    func displayPath() async -> String?
    /// Throws `.destinationPermissionExpired` if access cannot be established.
    func validateAccess() async throws
    /// Free bytes available at the destination for important usage.
    func availableCapacity() async throws -> Int64
    /// Atomically moves a fully verified staged file into the destination with
    /// collision-safe naming. Returns the final URL. Must never overwrite.
    func commit(stagedFile: URL, suggestedName: String) async throws -> URL
}

// MARK: - Settings

/// Minimal key/value persistence abstraction (UserDefaults in production).
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

// MARK: - Discovery

/// Browses for compatible peers. Emits the full current set on each change.
public protocol PeerDiscovering: AnyObject, Sendable {
    var peers: AsyncStream<[DiscoveredPeer]> { get }
    var state: AsyncStream<DiscoveryState> { get }
    func start() async
    func stop() async
}

public enum DiscoveryState: Sendable, Hashable {
    case idle
    case browsing
    case waiting(BridgeError.Code?)
    case failed(BridgeError.Code)
}
