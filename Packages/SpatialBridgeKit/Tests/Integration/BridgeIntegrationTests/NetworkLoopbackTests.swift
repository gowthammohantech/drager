import Foundation
import Network
import Testing
@testable import BridgeCore
@testable import BridgeModels
@testable import BridgeNetworking
@testable import BridgeSecurity
import BridgeTestSupport

/// Real Network.framework connections over 127.0.0.1: plain-TCP pairing,
/// TLS 1.2 ECDHE-PSK sessions, session authentication and framing.
@Suite("Network loopback", .serialized, .timeLimit(.minutes(2)))
struct NetworkLoopbackTests {
    static func waitForPort(_ read: () -> UInt16?) async throws -> UInt16 {
        for _ in 0..<100 {
            if let port = read() { return port }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw BridgeError(.timeout, detail: "listener never became ready")
    }

    static func endpoint(_ port: UInt16) -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// Pairs `phone` with `mac` over a real pairing listener and returns both outcomes.
    static func pair(phone: TestPeer, mac: TestPeer, advertiser: ServiceAdvertiser) async throws -> (phone: PairingOutcome, mac: PairingOutcome) {
        let port = try await waitForPort { advertiser.pairingPort }
        async let macOutcome: PairingOutcome = {
            for await incoming in advertiser.incoming {
                guard case .pairing(let transport) = incoming else { continue }
                let channel = SessionChannel(transport: transport, configuration: .handshake)
                return try await PairingProtocol.runResponder(
                    channel: channel, identity: mac.identity, device: mac.device,
                    rateLimiter: PairingRateLimiter(), decide: ScriptedDecision(approve: true).handler
                )
            }
            throw BridgeError(.peerLost)
        }()
        let transport = try await PeerConnector.openPairing(to: endpoint(port))
        let phoneOutcome = try await PairingProtocol.runInitiator(
            channel: SessionChannel(transport: transport, configuration: .handshake),
            identity: phone.identity, device: phone.device,
            decide: ScriptedDecision(approve: true).handler
        )
        return (phoneOutcome, try await macOutcome)
    }

    @Test("T-01/T-12: pair over TCP, then authenticate a TLS-PSK session and exchange keepalives")
    func pairThenSession() async throws {
        let phone = TestPeer.iPhone(), mac = TestPeer.mac()
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [], pairingEnabled: true)
        defer { advertiser.stop() }

        let outcomes = try await Self.pair(phone: phone, mac: mac, advertiser: advertiser)
        #expect(outcomes.phone.preSharedKey == outcomes.mac.preSharedKey)

        // The Mac now trusts the phone: restart the session listener with its PSK.
        let trust = InMemoryTrustDirectory([outcomes.mac.trustedPeer])
        advertiser.updateSessionKeys([(phone.identity.peerID, outcomes.mac.preSharedKey)])
        let port = try await Self.waitForPort { advertiser.sessionPort }

        let config = SessionChannel.Configuration(keepaliveInterval: .milliseconds(100), deadPeerTimeout: .seconds(5))
        async let macSide: (TrustedPeer, SessionChannel) = {
            for await incoming in advertiser.incoming {
                guard case .session(let transport) = incoming else { continue }
                let channel = SessionChannel(transport: transport, configuration: config)
                let result = try await SessionAuthenticator.authenticateAsResponder(channel: channel, identity: mac.identity, device: mac.device, trust: trust)
                return (result.peer, channel)
            }
            throw BridgeError(.peerLost)
        }()

        let transport = try await PeerConnector.openSession(
            to: Self.endpoint(port), identity: phone.identity.peerID, preSharedKey: outcomes.phone.preSharedKey
        )
        let phoneChannel = SessionChannel(transport: transport, configuration: config)
        let hello = try await SessionAuthenticator.authenticateAsInitiator(
            channel: phoneChannel, identity: phone.identity, device: phone.device, expectedPeer: outcomes.phone.trustedPeer
        )
        #expect(hello.device.peerID == mac.identity.peerID)
        let (authenticatedPeer, macChannel) = try await macSide
        #expect(authenticatedPeer.peerID == phone.identity.peerID)

        // Keepalive pings are answered and produce RTT samples.
        var sawRTT = false
        for await event in phoneChannel.events {
            if case .roundTripTime(let rtt) = event { sawRTT = rtt >= 0; break }
        }
        #expect(sawRTT)

        // Closing one side is observed by the other as E005.
        await macChannel.close()
        await #expect(throws: BridgeError.self) { _ = try await phoneChannel.receive() }
    }

    @Test("T-11: a client with an unknown PSK identity cannot complete the TLS handshake")
    func unknownIdentityRejected() async throws {
        let mac = TestPeer.mac(), trustedPhone = TestPeer.iPhone(), stranger = TestPeer.iPhone("Stranger")
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [(trustedPhone.identity.peerID, SecureRandom.bytes(32))], pairingEnabled: false)
        defer { advertiser.stop() }
        let port = try await Self.waitForPort { advertiser.sessionPort }
        await #expect {
            _ = try await PeerConnector.openSession(to: Self.endpoint(port), identity: stranger.identity.peerID, preSharedKey: SecureRandom.bytes(32))
        } throws: { ($0 as? BridgeError)?.code == .authenticationFailed }
    }

    @Test("A trusted identity with the wrong key fails the TLS handshake")
    func wrongKeyRejected() async throws {
        let mac = TestPeer.mac(), phone = TestPeer.iPhone()
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [(phone.identity.peerID, SecureRandom.bytes(32))], pairingEnabled: false)
        defer { advertiser.stop() }
        let port = try await Self.waitForPort { advertiser.sessionPort }
        await #expect {
            _ = try await PeerConnector.openSession(to: Self.endpoint(port), identity: phone.identity.peerID, preSharedKey: SecureRandom.bytes(32))
        } throws: { ($0 as? BridgeError)?.code == .authenticationFailed }
    }

    @Test("With several trusted iPhones, each connects with its own key")
    func multiplePeers() async throws {
        let mac = TestPeer.mac(), a = TestPeer.iPhone("A"), b = TestPeer.iPhone("B")
        let keyA = SecureRandom.bytes(32), keyB = SecureRandom.bytes(32)
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [(a.identity.peerID, keyA), (b.identity.peerID, keyB)], pairingEnabled: false)
        defer { advertiser.stop() }
        let port = try await Self.waitForPort { advertiser.sessionPort }
        let transport = try await PeerConnector.openSession(to: Self.endpoint(port), identity: b.identity.peerID, preSharedKey: keyB)
        await transport.close()
    }

    @Test("Pairing listener refuses connections once pairing is disabled")
    func pairingDisabled() async throws {
        let mac = TestPeer.mac()
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [], pairingEnabled: true)
        defer { advertiser.stop() }
        let port = try await Self.waitForPort { advertiser.pairingPort }
        advertiser.setPairingEnabled(false)
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: BridgeError.self) {
            let transport = try await PeerConnector.openPairing(to: Self.endpoint(port))
            // If the socket raced open, the listener must not hand it to the app.
            _ = try await SessionChannel(transport: transport, configuration: .handshake).receiveControl(timeout: .milliseconds(500))
        }
    }

    @Test("Large chunk streams over TLS arrive intact and in order")
    func chunkStream() async throws {
        let mac = TestPeer.mac(), phone = TestPeer.iPhone()
        let key = SecureRandom.bytes(32)
        let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
        advertiser.start(sessionKeys: [(phone.identity.peerID, key)], pairingEnabled: false)
        defer { advertiser.stop() }
        let port = try await Self.waitForPort { advertiser.sessionPort }

        let id = UUID()
        let chunkCount = 40
        let chunkSize = 256 * 1024
        async let received: Int = {
            for await incoming in advertiser.incoming {
                guard case .session(let transport) = incoming else { continue }
                let channel = SessionChannel(transport: transport, configuration: .handshake)
                var expectedOffset: UInt64 = 0
                for sequence in 0..<UInt32(chunkCount) {
                    guard case .chunk(let chunk) = try await channel.receive() else { throw BridgeError(.protocolMismatch) }
                    #expect(chunk.sequence == sequence)
                    #expect(chunk.offset == expectedOffset)
                    #expect(chunk.payload.first == UInt8(truncatingIfNeeded: sequence))
                    expectedOffset += UInt64(chunk.payload.count)
                    // Slow consumer: exercises backpressure through the bounded inbox.
                    if sequence % 8 == 0 { try await Task.sleep(for: .milliseconds(20)) }
                }
                await channel.close()
                return Int(expectedOffset)
            }
            return 0
        }()
        let transport = try await PeerConnector.openSession(to: Self.endpoint(port), identity: phone.identity.peerID, preSharedKey: key)
        for sequence in 0..<UInt32(chunkCount) {
            let payload = Data(repeating: UInt8(truncatingIfNeeded: sequence), count: chunkSize)
            try await transport.send(.chunk(ChunkFrame(transferID: id, sequence: sequence, offset: UInt64(sequence) * UInt64(chunkSize), payload: payload)))
        }
        #expect(try await received == chunkCount * chunkSize)
        await transport.close()
    }
}

/// Real Bonjour advertise/browse. Requires Local Network permission for the
/// test runner, so it only runs with `SB_ENABLE_BONJOUR_TESTS=1`.
@Suite("Bonjour discovery", .enabled(if: ProcessInfo.processInfo.environment["SB_ENABLE_BONJOUR_TESTS"] == "1"))
struct BonjourDiscoveryTests {
    @Test("A Mac advertising session and pairing instances is discovered as one peer with both roles")
    func discover() async throws {
        let mac = TestPeer.mac("Bonjour Test Mac \(Int.random(in: 1000...9999))")
        let advertiser = ServiceAdvertiser(device: mac.device)
        advertiser.start(sessionKeys: [], pairingEnabled: true)
        defer { advertiser.stop() }
        let browser = BonjourBrowser()
        await browser.start()
        defer { Task { await browser.stop() } }
        let found = try await withBridgeTimeout(.seconds(15)) {
            for await peers in browser.peers {
                if let peer = peers.first(where: { $0.advertisedPeerID == mac.identity.peerID }), peer.roles == [.session, .pairing] {
                    return peer
                }
            }
            throw BridgeError(.noPeer)
        }
        #expect(found.advertisedDisplayName == mac.device.displayName)
        #expect(browser.endpoint(for: found.id, role: .pairing) != nil)
    }
}
