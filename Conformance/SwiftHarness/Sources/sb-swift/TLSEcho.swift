import Foundation
import Network
import BridgeCore
import BridgeModels
import BridgeNetworking

/// `tls-echo`: TLS 1.2 PSK (0xCCAC) server or client with the production
/// parameters from `NetworkParameters`, for cross-stack TLS spikes.
enum TLSEcho {
    static func run(_ args: Args) async -> Int32 {
        do {
            let role = try args.required("role")
            let identity = PeerID(rawValue: try args.required("identity"))
            guard let psk = Data(hex: try args.required("psk-hex")), psk.count == 32 else {
                throw UsageError("--psk-hex must be 64 hex characters")
            }
            switch role {
            case "server": return try await server(args, identity: identity, psk: psk)
            case "client": return await client(args, identity: identity, psk: psk)
            default: throw UsageError("--role must be server or client")
            }
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            Out.error(bridgeCode(error))
            return exitCode(for: bridgeCode(error))
        }
    }

    static func server(_ args: Args, identity: PeerID, psk: Data) async throws -> Int32 {
        let (host, port) = try args.hostPort("listen")
        let parameters = NetworkParameters.serverSession(keys: [(identity: identity, preSharedKey: psk)])
        let (listener, bound) = try await Net.listen(host: host, port: port, parameters: parameters) { connection in
            Task { await echo(connection) }
        }
        Out.event("listening", ["port": Int(bound), "pskFingerprint": Out.pskFingerprint(psk)])
        // Serve until killed.
        while true {
            try? await Task.sleep(for: .seconds(3600))
            _ = listener
        }
    }

    private static func echo(_ connection: NWConnection) async {
        do {
            try await Net.ready(connection, timeout: .seconds(30))
            Out.event("tlsEstablished")
            while let data = try await Net.receive(connection) {
                if !data.isEmpty { try await Net.send(connection, data) }
            }
            Out.event("closed")
        } catch {
            // Wrong key / unknown identity: report and keep serving.
            Out.error(bridgeCode(error))
        }
        connection.cancel()
    }

    static func client(_ args: Args, identity: PeerID, psk: Data) async -> Int32 {
        do {
            let (host, port) = try args.hostPort("connect")
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw UsageError("bad port") }
            let connection = NWConnection(
                host: NWEndpoint.Host(host), port: nwPort,
                using: NetworkParameters.clientSession(identity: identity, preSharedKey: psk)
            )
            defer { connection.cancel() }
            try await Net.ready(connection)
            Out.event("tlsEstablished")
            let ping = Data("ping\n".utf8)
            try await Net.send(connection, ping)
            let received = try await withBridgeTimeout(.seconds(10)) {
                var received = Data()
                while received.count < ping.count {
                    guard let chunk = try await Net.receive(connection) else {
                        throw BridgeError(.peerLost, detail: "eof before echo")
                    }
                    received.append(chunk)
                }
                return received
            }
            guard received == ping else { throw BridgeError(.authenticationFailed, detail: "echo mismatch") }
            Out.event("echoOk")
            return 0
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            // Any client failure is reported as E004 per the lane contract.
            Out.event("error", ["code": BridgeError.Code.authenticationFailed.rawValue, "cause": bridgeCode(error).rawValue])
            return 4
        }
    }
}
