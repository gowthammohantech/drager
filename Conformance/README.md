# Conformance

The compatibility gate between the Swift, Kotlin and .NET implementations of the Spatial Bridge protocol. The rules are in [docs/API/CONFORMANCE.md](../docs/API/CONFORMANCE.md).

- `vectors/`: golden vectors generated from Swift by `Packages/SpatialBridgeKit/Tests/Conformance/VectorExportTests`. Do not edit them by hand.
  - Regenerate: `SB_WRITE_VECTORS=1 Scripts/test-packages.sh`
  - CI checks them without writing.
- `schema/`: the JSON Schema that every vector file follows.
- `SwiftHarness/`: the `sb-swift` test CLI. It is a separate SwiftPM package, so `SpatialBridgeKit` stays free of dependencies.
- `interop/`: the loopback interop matrix (`Scripts/interop.sh`). It runs `sb-swift`, `sb-jvm` and `sb-dotnet` against each other on 127.0.0.1.
