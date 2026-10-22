import Foundation
import BridgeModels

// MARK: - Hex

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = hexValue(chars[index]), let low = hexValue(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}

private func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
    default: nil
    }
}

// MARK: - Timeout

/// Runs `operation` and fails with `BridgeError(.timeout)` if it does not finish in time.
public func withBridgeTimeout<T: Sendable>(
    _ duration: Duration,
    clock: any BridgeClock = SystemClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: duration)
            throw BridgeError(.timeout)
        }
        guard let result = try await group.next() else {
            throw BridgeError(.timeout)
        }
        group.cancelAll()
        return result
    }
}

// MARK: - Retry

/// Exponential backoff with full jitter.
public struct RetryPolicy: Sendable, Hashable, Codable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    public var multiplier: Double

    public init(maxAttempts: Int = 5, initialDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(15), multiplier: Double = 2) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Delay before attempt `attempt` (1-based). Attempt 1 has no delay.
    public func delay(forAttempt attempt: Int, jitter: Double = Double.random(in: 0...1)) -> Duration {
        guard attempt > 1 else { return .zero }
        let base = initialDelay.timeInterval * pow(multiplier, Double(attempt - 2))
        let capped = min(base, maxDelay.timeInterval)
        return .seconds(capped * max(0, min(1, jitter)))
    }
}

// MARK: - Byte formatting

public enum ByteFormatting {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Privacy-safe size bucket for analytics (PRD §7).
    public static func bucket(_ bytes: Int64) -> String {
        switch bytes {
        case ..<(1 << 20): "<1MB"
        case ..<(10 << 20): "1-10MB"
        case ..<(50 << 20): "10-50MB"
        case ..<(100 << 20): "50-100MB"
        default: ">100MB"
        }
    }
}

// MARK: - Random

public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        for index in 0..<count {
            data[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return data
    }
}
