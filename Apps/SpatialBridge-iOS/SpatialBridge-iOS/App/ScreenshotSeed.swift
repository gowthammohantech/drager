import BridgeModels
import BridgePersistence
import BridgeServices
import UIKit
import UniformTypeIdentifiers

/// App Store screenshot state. Only reachable with `-ui-testing -screenshots`,
/// so it runs on in-memory stores and never touches the network or Keychain.
extension AppModel {
    static var isScreenshotMode: Bool {
        AppEnvironment.isUITesting && ProcessInfo.processInfo.arguments.contains("-screenshots")
    }

    func seedForScreenshots() async {
        let macID = PeerID(rawValue: "0123456789abcdef0123456789abcdef")
        let mac = TrustedPeer(
            peerID: macID, displayName: "Studio MacBook Pro", platform: .macOS, model: "Mac16,7",
            signingPublicKey: Data(repeating: 1, count: 32), pairedAt: .now.addingTimeInterval(-86_400 * 12), lastSeenAt: .now
        )
        try? await trustedStore.upsert(mac)
        link = LinkStatus(state: .connected, peer: mac, quality: .excellent, roundTripTime: 0.004)

        let now = Date.now
        let sent: [(String, String, Int64, TimeInterval)] = [
            ("Golden hour.heic", UTType.heic.identifier, 3_412_000, 60 * 4),
            ("Lisbon tram.jpeg", UTType.jpeg.identifier, 2_210_000, 60 * 18),
            ("Quarterly plan.pdf", UTType.pdf.identifier, 845_000, 60 * 52),
            ("Sketch v3.png", UTType.png.identifier, 1_604_000, 3_600 * 3),
            ("Voice memo.m4a", UTType.mpeg4Audio.identifier, 4_980_000, 3_600 * 26),
        ]
        for (name, type, bytes, ago) in sent {
            try? await historyStore.record(TransferRecord(
                id: UUID(), direction: .outgoing, filename: name, contentType: type, byteCount: bytes,
                peerID: macID, peerDisplayName: mac.displayName,
                startedAt: now.addingTimeInterval(-ago), finishedAt: now.addingTimeInterval(-ago + 1), state: .completed
            ))
        }
        await refreshStores()

        let photos: [(String, [UIColor])] = [
            ("Golden hour.heic", [.systemOrange, .systemPink, .systemPurple]),
            ("Lisbon tram.jpeg", [.systemYellow, .systemOrange, .systemRed]),
            ("Coastline.heic", [.systemTeal, .systemBlue, .systemIndigo]),
            ("Forest trail.jpeg", [.systemMint, .systemGreen, .systemTeal]),
        ]
        gallery.items = photos.map { name, colors in
            let image = Self.sampleImage(colors)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? image.jpegData(compressionQuality: 0.9)?.write(to: url)
            return StagedItem(
                id: UUID(), url: url, filename: name, contentType: UTType(filenameExtension: url.pathExtension) ?? .jpeg, byteCount: 3_412_000,
                readiness: .ready, thumbnail: image, pixelSize: CGSize(width: 4032, height: 3024)
            )
        }
        gallery.selectedID = gallery.items.first?.id

        if ProcessInfo.processInfo.arguments.contains("-screenshot-transfer") {
            transfer = TransferUIState(
                phase: .completed, filename: "Golden hour.heic", bytes: 3_412_000, total: 3_412_000,
                bytesPerSecond: 0, savedName: "Golden hour.heic", macName: mac.displayName
            )
        }
    }

    /// A soft sunset-style gradient with a sun and horizon, standing in for a photo.
    private static func sampleImage(_ colors: [UIColor]) -> UIImage {
        let size = CGSize(width: 900, height: 1000)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            cg.fillEllipse(in: CGRect(x: 520, y: 260, width: 220, height: 220))
            UIColor.black.withAlphaComponent(0.28).setFill()
            let hills = UIBezierPath()
            hills.move(to: CGPoint(x: 0, y: 700))
            hills.addCurve(to: CGPoint(x: size.width, y: 640), controlPoint1: CGPoint(x: 300, y: 560), controlPoint2: CGPoint(x: 600, y: 800))
            hills.addLine(to: CGPoint(x: size.width, y: size.height))
            hills.addLine(to: CGPoint(x: 0, y: size.height))
            hills.close()
            hills.fill()
        }
    }
}
