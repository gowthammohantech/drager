import Foundation

/// The product's user-facing error vocabulary (FRD §7). Every code carries an
/// actionable message and a recovery suggestion. `detail` is developer-facing
/// and must never contain file content or secrets.
public struct BridgeError: Error, Codable, Sendable, Hashable, LocalizedError {
    public enum Code: String, Codable, Sendable, Hashable, CaseIterable {
        case localNetworkDenied = "E001"
        case noPeer = "E002"
        case pairingRejected = "E003"
        case authenticationFailed = "E004"
        case peerLost = "E005"
        case unsupportedFile = "E006"
        case sizeLimit = "E007"
        case insufficientStorage = "E008"
        case destinationPermissionExpired = "E009"
        case hashMismatch = "E010"
        case writeFailed = "E011"
        case protocolMismatch = "E012"
        case transferCanceled = "E013"
        case timeout = "E014"

        public var userMessage: String {
            switch self {
            case .localNetworkDenied:
                "Drager isn't allowed to use the local network."
            case .noPeer:
                "No device was found nearby."
            case .pairingRejected:
                "Pairing was declined."
            case .authenticationFailed:
                "The device couldn't be verified."
            case .peerLost:
                "The connection to the other device was lost."
            case .unsupportedFile:
                "This file type isn't supported."
            case .sizeLimit:
                "This file is too large to send."
            case .insufficientStorage:
                "There isn't enough free space on the receiving device."
            case .destinationPermissionExpired:
                "Access to the destination folder has expired."
            case .hashMismatch:
                "The file arrived damaged and was discarded."
            case .writeFailed:
                "The receiving device couldn't save the file."
            case .protocolMismatch:
                "The other device is running an incompatible version."
            case .transferCanceled:
                "The transfer was cancelled."
            case .timeout:
                "The other device didn't respond in time."
            }
        }

        public var recoverySuggestion: String {
            switch self {
            case .localNetworkDenied:
                "Open Settings › Privacy & Security › Local Network and enable Drager."
            case .noPeer:
                "Make sure Drager is running on the computer, both devices are on the same Wi-Fi, and Availability is on."
            case .pairingRejected:
                "Try pairing again and confirm that the codes match on both devices."
            case .authenticationFailed:
                "Unpair the device on both sides and pair again."
            case .peerLost:
                "Check Wi-Fi on both devices and try again."
            case .unsupportedFile:
                "Choose a different file."
            case .sizeLimit:
                "Files up to 100 MB are supported in this version."
            case .insufficientStorage:
                "Free up space on the computer or choose another destination folder."
            case .destinationPermissionExpired:
                "Choose the destination folder again in Drager on the computer."
            case .hashMismatch:
                "Try sending the file again."
            case .writeFailed:
                "Check that the destination folder is writable and try again."
            case .protocolMismatch:
                "Update Drager on both devices."
            case .transferCanceled:
                "Flick the file again to retry."
            case .timeout:
                "Make sure the other device is awake and nearby, then try again."
            }
        }

        /// Whether a retry of the same operation can plausibly succeed without user action.
        public var isRetryable: Bool {
            switch self {
            case .peerLost, .timeout, .hashMismatch, .writeFailed, .noPeer: true
            default: false
            }
        }
    }

    public var code: Code
    public var detail: String?

    public init(_ code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var errorDescription: String? { code.userMessage }
    public var recoverySuggestion: String? { code.recoverySuggestion }
    public var isRetryable: Bool { code.isRetryable }

    // Convenience constructors.
    public static let localNetworkDenied = BridgeError(.localNetworkDenied)
    public static let noPeer = BridgeError(.noPeer)
    public static let pairingRejected = BridgeError(.pairingRejected)
    public static let authenticationFailed = BridgeError(.authenticationFailed)
    public static let peerLost = BridgeError(.peerLost)
    public static let unsupportedFile = BridgeError(.unsupportedFile)
    public static let sizeLimit = BridgeError(.sizeLimit)
    public static let insufficientStorage = BridgeError(.insufficientStorage)
    public static let destinationPermissionExpired = BridgeError(.destinationPermissionExpired)
    public static let hashMismatch = BridgeError(.hashMismatch)
    public static let writeFailed = BridgeError(.writeFailed)
    public static let protocolMismatch = BridgeError(.protocolMismatch)
    public static let transferCanceled = BridgeError(.transferCanceled)
    public static let timeout = BridgeError(.timeout)
}

extension BridgeError {
    /// Maps any error to a `BridgeError`, preserving existing codes and
    /// classifying cancellation. Unknown errors become `.peerLost` when the
    /// caller says they came from the network, otherwise `.writeFailed`.
    public static func wrap(_ error: any Error, networkContext: Bool) -> BridgeError {
        if let bridge = error as? BridgeError { return bridge }
        if error is CancellationError { return BridgeError(.transferCanceled) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return BridgeError(.insufficientStorage, detail: ns.localizedDescription)
        }
        return BridgeError(networkContext ? .peerLost : .writeFailed, detail: "\(ns.domain) \(ns.code)")
    }
}
