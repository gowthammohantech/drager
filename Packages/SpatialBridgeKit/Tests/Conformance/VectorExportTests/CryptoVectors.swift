import CryptoKit
import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeSecurity

// MARK: - pairing.json

enum PairingVectors {
    struct Party {
        var seed: Data
        var ephemeral: Data
        var nonce: Data
        var challenge: Data
        var name: String
        var platform: DevicePlatform
        var model: String
    }

    static let scenarios: [(String, Party, Party)] = [
        ("iOS initiator, macOS responder",
         Party(seed: Fixtures.phoneSeed, ephemeral: counting(from: 0x11), nonce: counting(from: 0x21), challenge: counting(from: 0x31), name: "Insane", platform: .iOS, model: "iPhone18,2"),
         Party(seed: Fixtures.macSeed, ephemeral: counting(from: 0x51), nonce: counting(from: 0x61), challenge: counting(from: 0x71), name: "Studio Mac", platform: .macOS, model: "Mac16,1")),
        ("android initiator, windows responder, non-ASCII names",
         Party(seed: Fixtures.androidSeed, ephemeral: counting(from: 0x91), nonce: counting(from: 0xA1), challenge: counting(from: 0xB1), name: "Zoë’s \"Pixel\" 😀", platform: .android, model: "Pixel 9"),
         Party(seed: Fixtures.windowsSeed, ephemeral: counting(from: 0xD1), nonce: counting(from: 0xE1), challenge: counting(from: 0xF1), name: "Büro-PC/שלום", platform: .windows, model: "Surface Laptop 7")),
    ]

    static func cases(book: SignatureBook) throws -> [VectorCase] {
        try scenarios.map { name, i, r in
            let iID = Fixtures.identity(seed: i.seed), rID = Fixtures.identity(seed: r.seed)
            let iEph = Fixtures.ephemeral(i.ephemeral), rEph = Fixtures.ephemeral(r.ephemeral)
            let iHello = Hello(device: Fixtures.device(iID, i.name, i.platform, i.model), capabilities: [Hello.pairingCapability], sessionNonce: i.nonce)
            let rHello = Hello(device: Fixtures.device(rID, r.name, r.platform, r.model), capabilities: [Hello.pairingCapability], sessionNonce: r.nonce)
            let iHelloPayload = try ControlMessageCoder.encode(.hello(iHello))
            let rHelloPayload = try ControlMessageCoder.encode(.hello(rHello))
            let transcript = PairingTranscript(
                initiatorHello: iHello, initiatorHelloPayload: iHelloPayload,
                responderHello: rHello, responderHelloPayload: rHelloPayload,
                initiatorEphemeralPublicKey: iEph.publicKey.rawRepresentation,
                responderEphemeralPublicKey: rEph.publicKey.rawRepresentation,
                initiatorSigningPublicKey: iID.publicKeyData, responderSigningPublicKey: rID.publicKeyData,
                initiatorChallenge: i.challenge, responderChallenge: r.challenge
            )
            let keys = try PairingCrypto.derive(ephemeralPrivateKey: iEph, peerEphemeralPublicKey: rEph.publicKey.rawRepresentation, transcript: transcript)
            let keysR = try PairingCrypto.derive(ephemeralPrivateKey: rEph, peerEphemeralPublicKey: iEph.publicKey.rawRepresentation, transcript: transcript)
            #expect(keys == keysR)

            // The OKM and SAS key aren't exposed by PairingKeys; expand them here and check
            // they agree with the production split.
            let shared = try iEph.sharedSecretFromKeyAgreement(with: rEph.publicKey)
            let sharedBytes = shared.withUnsafeBytes { Data($0) }
            let okm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: keys.transcriptHash, sharedInfo: Data("sb-pair-v1-keys".utf8), outputByteCount: 96).withUnsafeBytes { Data($0) }
            let sasKey = okm.prefix(32)
            #expect(Data(okm[32..<64]) == keys.preSharedKey)
            #expect(Data(okm[64..<96]) == keys.confirmKey)
            #expect(PairingCrypto.shortAuthenticationString(from: Data(sasKey)) == keys.shortAuthenticationString)

            let confirmI = PairingCrypto.confirmation(keys: keys, role: .initiator, approvedPeer: rID.peerID)
            let confirmR = PairingCrypto.confirmation(keys: keys, role: .responder, approvedPeer: iID.peerID)
            let sigR = try book.signature(rID, over: keys.transcriptHash)
            let sigI = try book.signature(iID, over: keys.transcriptHash)

            let request = PairRequest(ephemeralPublicKey: iEph.publicKey.rawRepresentation, signingPublicKey: iID.publicKeyData, displayName: iHello.device.displayName, challenge: i.challenge)
            let response = PairResponse(ephemeralPublicKey: rEph.publicKey.rawRepresentation, signingPublicKey: rID.publicKeyData, displayName: rHello.device.displayName, challenge: r.challenge, transcriptSignature: sigR)
            let confirmInitiatorMsg = PairConfirm(challengeResponse: confirmI, approvedPeerID: rID.peerID, transcriptSignature: sigI)
            let confirmResponderMsg = PairConfirm(challengeResponse: confirmR, approvedPeerID: iID.peerID, transcriptSignature: Data())
            func wire(_ m: ControlMessage) throws -> JV { .hex(try ControlMessageCoder.encode(m)) }

            return [
                "name": .string(name),
                "initiatorSigningSeed": .hex(i.seed), "initiatorSigningPublicKey": .hex(iID.publicKeyData), "initiatorPeerID": .string(iID.peerID.rawValue),
                "responderSigningSeed": .hex(r.seed), "responderSigningPublicKey": .hex(rID.publicKeyData), "responderPeerID": .string(rID.peerID.rawValue),
                "initiatorEphemeralPrivateKey": .hex(i.ephemeral), "initiatorEphemeralPublicKey": .hex(iEph.publicKey.rawRepresentation),
                "responderEphemeralPrivateKey": .hex(r.ephemeral), "responderEphemeralPublicKey": .hex(rEph.publicKey.rawRepresentation),
                "initiatorNonce": .hex(i.nonce), "responderNonce": .hex(r.nonce),
                "initiatorChallenge": .hex(i.challenge), "responderChallenge": .hex(r.challenge),
                "initiatorHello": .hex(iHelloPayload), "initiatorHelloJson": .string(String(decoding: iHelloPayload, as: UTF8.self)),
                "responderHello": .hex(rHelloPayload), "responderHelloJson": .string(String(decoding: rHelloPayload, as: UTF8.self)),
                "sharedSecret": .hex(sharedBytes),
                "transcriptHash": .hex(keys.transcriptHash),
                "okm": .hex(okm), "sasKey": .hex(Data(sasKey)), "psk": .hex(keys.preSharedKey), "confirmKey": .hex(keys.confirmKey),
                "pskFingerprint": .string(String(sha256Hex(keys.preSharedKey).prefix(16))),
                "sas": .string(keys.shortAuthenticationString), "sasDisplay": .string(PairingCrypto.formatForDisplay(keys.shortAuthenticationString)),
                "confirmInitiator": .hex(confirmI), "confirmResponder": .hex(confirmR),
                "responderTranscriptSignature": try book.signatureObject(rID, over: keys.transcriptHash),
                "initiatorTranscriptSignature": try book.signatureObject(iID, over: keys.transcriptHash),
                "messages": [
                    "pairRequest": try wire(.pairRequest(request)),
                    "pairResponse": try wire(.pairResponse(response)),
                    "pairConfirmInitiator": try wire(.pairConfirm(confirmInitiatorMsg)),
                    "pairConfirmResponder": try wire(.pairConfirm(confirmResponderMsg)),
                ],
            ]
        }
    }
}

// MARK: - session-auth.json

enum SessionAuthVectors {
    static func cases(book: SignatureBook) throws -> [VectorCase] {
        let scenarios: [(String, DeviceIdentity, DeviceIdentity, Data, Data)] = [
            ("iOS to macOS", Fixtures.phone, Fixtures.mac, counting(from: 0x02), counting(from: 0x82)),
            ("android to windows", Fixtures.android, Fixtures.windows, Data(repeating: 0xAA, count: 32), Data(repeating: 0x55, count: 32)),
        ]
        var out: [VectorCase] = []
        for (name, initiator, responder, iNonce, rNonce) in scenarios {
            for (role, signer) in [(PairingRole.initiator, initiator), (.responder, responder)] {
                let context = SessionAuthenticator.signedContext(
                    initiatorNonce: iNonce, responderNonce: rNonce,
                    initiator: initiator.peerID, responder: responder.peerID, signer: role
                )
                let signature = try book.signature(signer, over: context)
                out.append([
                    "name": .string("\(name), \(role.rawValue) signs"),
                    "role": .string(role.rawValue),
                    "initiatorNonce": .hex(iNonce), "responderNonce": .hex(rNonce),
                    "initiatorPeerID": .string(initiator.peerID.rawValue), "responderPeerID": .string(responder.peerID.rawValue),
                    "signerPublicKey": .hex(signer.publicKeyData),
                    "signedContext": .hex(context),
                    "sessionAuthJson": .string(String(decoding: try ControlMessageCoder.encode(.sessionAuth(SessionAuth(signature: signature))), as: UTF8.self)),
                    "signature": try book.signatureObject(signer, over: context),
                ])
            }
        }
        return out
    }
}

// MARK: - ed25519.json

enum Ed25519Vectors {
    static func cases(book: SignatureBook) throws -> [VectorCase] {
        var out: [VectorCase] = []
        func add(_ name: String, publicKey: Data, message: Data, signature: Data, valid: Bool, extra: VectorCase = [:]) {
            #expect(DeviceIdentity.verify(signature: signature, over: message, publicKey: publicKey) == valid, "\(name)")
            var c: VectorCase = ["name": .string(name), "publicKey": .hex(publicKey), "message": .hex(message), "signature": .hex(signature), "valid": .bool(valid)]
            c.merge(extra) { a, _ in a }
            out.append(c)
        }

        // RFC 8032 §7.1 tests 1–3 (deterministic signatures).
        let rfc: [(String, String, String, String, String)] = [
            ("RFC 8032 test 1 (empty message)",
             "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
             "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
             "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            ("RFC 8032 test 2 (one byte)",
             "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
             "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
             "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
            ("RFC 8032 test 3 (two bytes)",
             "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
             "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
             "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
        ]
        for (name, seed, pk, msg, sig) in rfc {
            let identity = Fixtures.identity(seed: unhex(seed))
            #expect(hexString(identity.publicKeyData) == pk, "\(name): public key from seed")
            add(name, publicKey: unhex(pk), message: unhex(msg), signature: unhex(sig), valid: true, extra: ["privateKeySeed": .string(seed), "deterministic": true])
        }

        // CryptoKit signatures (randomized: verify-only).
        let phone = Fixtures.phone, mac = Fixtures.mac
        let message = Data("Spatial Bridge ed25519 vector".utf8)
        let hashMessage = Data(SHA256.hash(data: message))
        let sig = try book.signature(phone, over: message)
        let sig2 = try book.signature(mac, over: hashMessage)
        add("CryptoKit signature over text", publicKey: phone.publicKeyData, message: message, signature: sig, valid: true, extra: ["verifyOnly": true, "privateKeySeed": .hex(Fixtures.phoneSeed)])
        add("CryptoKit signature over 32-byte hash", publicKey: mac.publicKeyData, message: hashMessage, signature: sig2, valid: true, extra: ["verifyOnly": true, "privateKeySeed": .hex(Fixtures.macSeed)])

        // Invalid variants of the first CryptoKit case.
        var flippedMessage = message; flippedMessage[0] ^= 0x01
        add("invalid: flipped message bit", publicKey: phone.publicKeyData, message: flippedMessage, signature: sig, valid: false)
        var flippedR = sig; flippedR[0] ^= 0x01
        add("invalid: flipped signature bit in R", publicKey: phone.publicKeyData, message: message, signature: flippedR, valid: false)
        var flippedS = sig; flippedS[40] ^= 0x01
        add("invalid: flipped signature bit in S", publicKey: phone.publicKeyData, message: message, signature: flippedS, valid: false)
        add("invalid: wrong public key", publicKey: mac.publicKeyData, message: message, signature: sig, valid: false)
        add("invalid: truncated signature (63 bytes)", publicKey: phone.publicKeyData, message: message, signature: sig.prefix(63), valid: false)
        add("invalid: empty signature", publicKey: phone.publicKeyData, message: message, signature: Data(), valid: false)
        add("invalid: short public key (31 bytes)", publicKey: phone.publicKeyData.prefix(31), message: message, signature: sig, valid: false)
        var rfcBad = unhex(rfc[1].4); rfcBad[63] ^= 0x80
        add("invalid: RFC 8032 test 2 with top bit of S set", publicKey: unhex(rfc[1].2), message: unhex(rfc[1].3), signature: rfcBad, valid: false)
        return out
    }
}
