import Foundation
import BridgeModels
import BridgeSecurity

/// `unpair --state DIR --peer PEERID`: forgets a peer (trust entry and pair PSK).
///
/// Idempotent: unpairing an unknown peer still succeeds. A `serve` running on the same
/// state directory notices within `UnpairWatcher.interval` and prints its own `unpaired`.
enum UnpairCommand {
    static func run(_ args: Args) async -> Int32 {
        do {
            let state = try HarnessState(path: try args.required("state"))
            guard let peer = PeerID(validating: try args.required("peer")) else {
                throw UsageError("--peer must be a peer ID (32 lowercase hex characters)")
            }
            try await state.forget(peer)
            Out.event("unpaired", ["peerID": peer.rawValue])
            return 0
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            Out.error(bridgeCode(error))
            return exitCode(for: bridgeCode(error))
        }
    }
}

/// Polls the state's secrets file for pair PSKs that another process removed.
///
/// The baseline is every peer the poll has seen plus every peer this process paired (`add`), so
/// an unpair that lands between a pairing and the next poll is still noticed.
actor UnpairWatcher {
    static let interval: Duration = .milliseconds(200)

    private let state: HarnessState
    private var known: Set<PeerID>

    init(state: HarnessState) {
        self.state = state
        known = Set((try? state.pairSecrets.pairedPeers()) ?? [])
    }

    func add(_ peer: PeerID) {
        known.insert(peer)
    }

    /// Peers whose PSK disappeared since they were last known.
    func poll() -> [PeerID] {
        guard let current = try? state.pairSecrets.pairedPeers() else { return [] }
        let now = Set(current)
        let removed = known.subtracting(now).sorted { $0.rawValue < $1.rawValue }
        known = now
        return removed
    }
}
