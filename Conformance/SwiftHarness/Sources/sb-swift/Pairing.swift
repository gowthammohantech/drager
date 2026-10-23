import Foundation
import Network
import BridgeCore
import BridgeModels
import BridgeNetworking
import BridgeSecurity

enum Decision {
    static func parse(_ args: Args) throws -> Bool {
        switch try args.required("decision") {
        case "approve": return true
        case "reject": return false
        default: throw UsageError("--decision must be approve or reject")
        }
    }

    /// Auto-answers the SAS prompt, printing the code first.
    static func handler(approve: Bool) -> PairingDecisionHandler {
        { prompt in
            Out.event("sas", ["code": prompt.shortAuthenticationString])
            return approve
        }
    }
}

enum PairCommands {
    /// `pair-initiate`: sender-side pairing over plain TCP.
    static func initiate(_ args: Args) async -> Int32 {
        do {
            let state = try HarnessState(path: try args.required("state"))
            let approve = try Decision.parse(args)
            let timeouts = HarnessTimeouts(testMode: args.flag("test-mode"))
            let (host, port) = try args.hostPort("connect")
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw UsageError("bad port") }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NetworkParameters.pairing())
            let transport = try await NWFrameTransport.open(connection, limits: timeouts.limits)
            let channel = SessionChannel(transport: transport, configuration: .handshake)
            let outcome = try await PairingProtocol.runInitiator(
                channel: channel, identity: state.identity, device: state.device(platform: .iOS),
                timeouts: timeouts.pairing, decide: Decision.handler(approve: approve)
            )
            try await state.remember(outcome)
            paired(outcome)
            Out.event("done")
            return 0
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            return pairFailed(error)
        }
    }

    /// `pair-respond`: receiver-side pairing. Handles exactly one pairing attempt, then exits.
    static func respond(_ args: Args) async -> Int32 {
        do {
            let state = try HarnessState(path: try args.required("state"))
            let approve = try Decision.parse(args)
            let timeouts = HarnessTimeouts(testMode: args.flag("test-mode"))
            let (host, port) = try args.hostPort("listen")
            let connections = AsyncStream<NWConnection>.makeStream()
            let (listener, bound) = try await Net.listen(host: host, port: port, parameters: NetworkParameters.pairing()) { connection in
                connections.continuation.yield(connection)
            }
            defer { listener.cancel() }
            Out.event("listening", ["port": Int(bound), "pairingPort": Int(bound)])
            for await connection in connections.stream {
                let transport: NWFrameTransport
                do {
                    transport = try await NWFrameTransport.open(connection, limits: timeouts.limits)
                } catch {
                    continue
                }
                listener.cancel()
                let channel = SessionChannel(transport: transport, configuration: .handshake)
                do {
                    let outcome = try await PairingProtocol.runResponder(
                        channel: channel, identity: state.identity, device: state.device(platform: .macOS),
                        rateLimiter: PairingRateLimiter(), timeouts: timeouts.pairing, decide: Decision.handler(approve: approve)
                    )
                    try await state.remember(outcome)
                    paired(outcome)
                    Out.event("done")
                    return 0
                } catch {
                    return pairFailed(error)
                }
            }
            return pairFailed(BridgeError(.peerLost))
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            return pairFailed(error)
        }
    }

    static func paired(_ outcome: PairingOutcome) {
        Out.event("paired", [
            "peerID": outcome.trustedPeer.peerID.rawValue,
            "pskFingerprint": Out.pskFingerprint(outcome.preSharedKey),
        ])
    }

    static func pairFailed(_ error: any Error) -> Int32 {
        let code = bridgeCode(error)
        Out.event("pairFailed", ["code": code.rawValue])
        return exitCode(for: code)
    }
}
