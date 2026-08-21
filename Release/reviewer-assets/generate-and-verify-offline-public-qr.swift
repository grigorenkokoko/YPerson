import AppKit
import Foundation

#if REVIEWER_ASSET_TOOL
// Models.swift also contains sync wire types; the QR fixture does not depend on
// private fields, but the standalone compiler needs this shape to type-check it.
struct PrivateCardFields: Codable, Equatable {
    let phone: String
}
#endif

private enum AssetFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
private enum OfflinePublicQRAssetTool {
    private static let expectedIssuerInstallationID = "11111111-2222-4333-8444-555555555555"
    private static let expectedCard = PersonCard(
        id: "person-review-dmitry",
        name: "Дмитрий Волков",
        role: "Tech Lead",
        company: "Signal Garden",
        phone: "",
        email: "dmitry@example.net",
        tagline: "Создаю понятные и доступные продукты.",
        hasAudioGreeting: false,
        meetingPlace: nil,
        isBlocked: false,
        templateID: CardTemplateCatalog.standardClean.id,
        version: 1,
        sourceInstallationID: nil,
        syncState: .localOnly
    )
    private static let expectedPixelSide = 808

    static func main() throws {
        let assetDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let payloadURL = assetDirectory.appendingPathComponent("offline-public-qr-payload.txt")
        let imageURL = assetDirectory.appendingPathComponent("test-qr.png")
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--print-payload"] {
            print(try ExchangePayloadCodec.encode(expectedPayload))
            return
        }
        let shouldWrite = arguments == ["--write"]
        guard shouldWrite || arguments.isEmpty else {
            throw AssetFailure.failed("usage: tool [--write|--print-payload]")
        }

        let payload = try String(contentsOf: payloadURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var failures: [String] = []

        do {
            let decoded = try ExchangePayloadCodec.decode(payload)
            try validatePublicFixture(decoded)
            let canonical = try ExchangePayloadCodec.encode(decoded)
            if canonical != payload {
                failures.append("source payload is not the canonical production encoding")
            }
        } catch {
            failures.append("production ExchangePayloadCodec rejected the source payload: \(error)")
        }

        guard failures.isEmpty else {
            throw AssetFailure.failed(failures.joined(separator: "\n"))
        }
        if shouldWrite {
            try runRenderer(in: assetDirectory)
        }

        let imageData = try Data(contentsOf: imageURL)
        do {
            let dimensions = try imageDimensions(imageData)
            if dimensions.width != expectedPixelSide || dimensions.height != expectedPixelSide {
                failures.append("PNG dimensions \(dimensions.width)x\(dimensions.height) do not match deterministic dimensions \(expectedPixelSide)x\(expectedPixelSide)")
            }
            print("PNG dimensions: \(dimensions.width)x\(dimensions.height)")
        } catch {
            failures.append("PNG cannot be opened for a dimension check: \(error)")
        }

        guard failures.isEmpty else {
            throw AssetFailure.failed(failures.joined(separator: "\n"))
        }
        print("Offline public payload fields and PNG dimensions verified with production Swift models.")
    }

    private static var expectedPayload: ExchangePayload {
        ExchangePayload(
            version: 2,
            issuerInstallationID: expectedIssuerInstallationID,
            card: expectedCard,
            exchangeToken: nil,
            expiresAt: nil
        )
    }

    private static func validatePublicFixture(_ payload: ExchangePayload) throws {
        guard payload.version == 2 else { throw AssetFailure.failed("fixture version must be 2") }
        guard payload.issuerInstallationID == expectedIssuerInstallationID else {
            throw AssetFailure.failed("fixture issuer installation ID changed")
        }
        guard payload.card == expectedCard else {
            throw AssetFailure.failed("fixture identity or public card fields changed")
        }
        guard payload.card.phone.isEmpty,
              payload.card.meetingPlace == nil,
              payload.card.sourceInstallationID == nil,
              payload.exchangeToken == nil,
              payload.expiresAt == nil else {
            throw AssetFailure.failed("offline fixture contains private, meeting, token, or expiry data")
        }
    }

    private static func runRenderer(in assetDirectory: URL) throws {
        let rendererURL = assetDirectory.appendingPathComponent("render-offline-public-qr.cjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", rendererURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let message = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if !message.isEmpty { print(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard process.terminationStatus == 0 else {
            throw AssetFailure.failed("deterministic QR renderer failed with status \(process.terminationStatus)")
        }
    }

    private static func imageDimensions(_ imageData: Data) throws -> (width: Int, height: Int) {
        guard let image = NSImage(data: imageData),
              let bitmap = NSBitmapImageRep(data: imageData) else {
            throw AssetFailure.failed("PNG cannot be opened")
        }
        _ = image
        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }

}
