import Foundation
import Testing

/// Golden vectors for the Kotlin and .NET ports (docs/API/CONFORMANCE.md §6).
/// `SB_WRITE_VECTORS=1` writes `Conformance/vectors/*.json`; otherwise each test
/// fails if the file on disk differs from what the Swift implementation produces.
@Suite("Conformance vector export")
struct VectorExportTests {
    @Test("framing.json") func framing() throws {
        try VectorFile.export("framing") { _ in try FramingVectors.cases() }
    }

    @Test("control-messages.json") func controlMessages() throws {
        try VectorFile.export("control-messages") { _ in try ControlMessageVectors.cases() }
    }

    @Test("canonical-json.json") func canonicalJSON() throws {
        try VectorFile.export("canonical-json") { _ in try CanonicalJSONVectors.cases() }
    }

    @Test("pairing.json") func pairing() throws {
        try VectorFile.export("pairing") { try PairingVectors.cases(book: $0) }
    }

    @Test("session-auth.json") func sessionAuth() throws {
        try VectorFile.export("session-auth") { try SessionAuthVectors.cases(book: $0) }
    }

    @Test("ed25519.json") func ed25519() throws {
        try VectorFile.export("ed25519") { try Ed25519Vectors.cases(book: $0) }
    }

    @Test("sanitizer.json") func sanitizer() throws {
        try VectorFile.export("sanitizer") { _ in SanitizerVectors.cases() }
    }

    @Test("uti-policy.json") func utiPolicy() throws {
        try VectorFile.export("uti-policy") { _ in UTIPolicyVectors.cases() }
    }

    @Test("coordinate-mapper.json") func coordinateMapper() throws {
        try VectorFile.export("coordinate-mapper") { _ in CoordinateMapperVectors.cases() }
    }
}
