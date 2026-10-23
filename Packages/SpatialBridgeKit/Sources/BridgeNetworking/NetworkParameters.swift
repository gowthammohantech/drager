import Foundation
public import Network
public import BridgeModels
import Security

/// Connection parameters for the two kinds of connection (ADR-010).
///
/// Sessions use TLS 1.2 with `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`:
/// the pair PSK authenticates both sides and ECDHE adds forward secrecy.
/// TLS 1.3 external-PSK-only handshakes are not supported by Network.framework
/// (verified on Xcode 27 SDK, see docs/ADR/ADR-010.md), so 1.3 is not offered.
/// There is no certificate verify block anywhere: unknown identities and
/// wrong keys fail the handshake.
///
/// Network.framework cannot restrict the offered suites. Once a PSK is
/// configured it always adds the plain-PSK suites 0x00A8, 0x00A9, 0x00AF and
/// 0x00AE (no ECDHE, so no forward secrecy) after anything appended, and no
/// `tls_ciphersuite_group_t` removes them. A server will negotiate 0x00A8 with
/// a client that offers only plain PSK. Every TLS connection is therefore
/// checked with `validateNegotiatedTLS(_:)` once it is ready and dropped
/// (E004) unless it negotiated TLS 1.2 with 0xCCAC.
public enum NetworkParameters {
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905).
    public static let sessionCipherSuite: UInt16 = 0xCCAC
    /// The only accepted protocol version (TLS 1.2).
    public static let sessionProtocolVersion: UInt16 = 0x0303

    /// Fails with E004 unless a TLS connection negotiated TLS 1.2 with
    /// 0xCCAC. Connections whose parameters carry no TLS (pairing) pass.
    /// Call it when the connection is `.ready`, before any application data.
    public static func validateNegotiatedTLS(_ connection: NWConnection) throws(BridgeError) {
        let usesTLS = connection.parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options }
        guard usesTLS else { return }
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw BridgeError(.authenticationFailed, detail: "TLS metadata missing")
        }
        let negotiated = negotiatedTLS(metadata)
        try validate(suite: negotiated.suite, version: negotiated.version)
    }

    /// The negotiated suite and version as wire values.
    public static func negotiatedTLS(_ metadata: NWProtocolTLS.Metadata) -> (suite: UInt16, version: UInt16) {
        let security = metadata.securityProtocolMetadata
        return (
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue,
            sec_protocol_metadata_get_negotiated_tls_protocol_version(security).rawValue
        )
    }

    static func validate(suite: UInt16, version: UInt16) throws(BridgeError) {
        guard version == sessionProtocolVersion else {
            throw BridgeError(.authenticationFailed, detail: "TLS version \(hex(version)) not allowed")
        }
        guard suite == sessionCipherSuite else {
            throw BridgeError(.authenticationFailed, detail: "TLS suite \(hex(suite)) not allowed")
        }
    }

    private static func hex(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// iPhone → Mac session. `identity` is the iPhone's own peer ID.
    public static func clientSession(identity: PeerID, preSharedKey: Data) -> NWParameters {
        precondition(preSharedKey.count == 32)
        return make(tls: tlsOptions(keys: [(identity, preSharedKey)]))
    }

    /// Mac listener accepting any trusted iPhone. One PSK per trusted peer;
    /// the TLS stack selects by identity. With no trusted peers a random
    /// throwaway key keeps the listener valid while rejecting everyone.
    public static func serverSession(keys: [(identity: PeerID, preSharedKey: Data)]) -> NWParameters {
        let effective = keys.isEmpty ? [(PeerID(rawValue: "sb-no-trusted-peers"), randomKey())] : keys.map { ($0.identity, $0.preSharedKey) }
        return make(tls: tlsOptions(keys: effective))
    }

    /// Plain TCP for the pairing handshake. Nothing secret crosses it before the
    /// ECDH exchange; MITM resistance comes from the SAS comparison.
    public static func pairing() -> NWParameters {
        make(tls: nil)
    }

    private static func make(tls: NWProtocolTLS.Options?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .responsiveData
        return parameters
    }

    private static func tlsOptions(keys: [(PeerID, Data)]) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(security, dispatchData(key), dispatchData(Data(identity.rawValue.utf8)))
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        // Puts 0xCCAC first, so the client offers it first and the server
        // prefers it. This does not remove the plain-PSK suites (see above).
        if let suite = tls_ciphersuite_t(rawValue: sessionCipherSuite) {
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_renegotiation_enabled(security, false)
        return tls
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    private static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
