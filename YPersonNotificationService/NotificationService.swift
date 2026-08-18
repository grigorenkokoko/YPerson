import CryptoKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestContent: UNMutableNotificationContent?
    private var task: URLSessionDataTask?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { contentHandler(request.content); return }
        bestContent = content
        var visibleInfo = content.userInfo
        visibleInfo.removeValue(forKey: "exchange_token")
        content.userInfo = visibleInfo

        guard let cardID = content.userInfo["card_id"] as? String,
              let signature = content.userInfo["card_signature"] as? String,
              verify(cardID: cardID, signature: signature),
              let avatarString = content.userInfo["public_avatar_url"] as? String,
              let avatarURL = URL(string: avatarString), avatarURL.scheme == "https" else {
            finish(content)
            return
        }

        task = session.dataTask(with: avatarURL) { [weak self] data, response, _ in
            guard let self, let data, data.count <= 1_000_000,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { self?.finish(content); return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent("avatar.jpg")
                try data.write(to: fileURL, options: .atomic)
                content.attachments = [try UNNotificationAttachment(identifier: "public-avatar", url: fileURL)]
            } catch { }
            self.finish(content)
        }
        task?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        if let bestContent { finish(bestContent) }
    }

    private func verify(cardID: String, signature: String) -> Bool {
        guard cardID.range(of: #"^[a-zA-Z0-9-]{3,80}$"#, options: .regularExpression) != nil,
              let signatureData = Data(base64Encoded: signature),
              let encodedKey = Bundle.main.object(forInfoDictionaryKey: "NOTIFICATION_SIGNING_PUBLIC_KEY") as? String,
              let keyData = Data(base64Encoded: encodedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(signatureData, for: Data(cardID.utf8))
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }
}
