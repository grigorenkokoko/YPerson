import Foundation

final class APIClient {
    enum ClientError: LocalizedError {
        case invalidResponse
        case status(Int, String)
        case unexpectedConfigurationField(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Сервер вернул некорректный ответ."
            case .status(let code, let message): return "Ошибка сервера \(code): \(message)"
            case .unexpectedConfigurationField(let field): return "Конфигурация содержит недопустимое поле: \(field)."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let snapshotStore: AppGroupSnapshotStore?
    private let credential: InstallationCredential
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    var installationID: String { credential.installationID }

    init(baseURL: URL, session: URLSession, snapshotStore: AppGroupSnapshotStore?, credential: InstallationCredential) {
        self.baseURL = baseURL
        self.session = session
        self.snapshotStore = snapshotStore
        self.credential = credential
        self.decoder = Self.makeDecoder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO 8601 date"
                )
            }
            return date
        }
        return decoder
    }

    func fetchConfiguration() async throws -> RemoteConfiguration {
        try await Self.fetchPublicConfiguration(
            baseURL: baseURL,
            session: session,
            snapshotStore: snapshotStore
        )
    }

    static func fetchPublicConfiguration(
        baseURL: URL,
        session: URLSession,
        snapshotStore: AppGroupSnapshotStore?
    ) async throws -> RemoteConfiguration {
        let url = baseURL.appendingPathComponent("config")
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = snapshotStore?.cachedConfiguration()?.1 {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            if http.statusCode == 304, let cached = snapshotStore?.cachedConfiguration()?.0 { return cached }
            guard http.statusCode == 200 else {
                throw ClientError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            try validateConfigurationShape(data)
            let configuration = try makeDecoder().decode(RemoteConfiguration.self, from: data)
            try snapshotStore?.cacheConfiguration(configuration, etag: http.value(forHTTPHeaderField: "ETag"))
            return configuration
        } catch {
            if let cached = snapshotStore?.cachedConfiguration()?.0 { return cached }
            throw error
        }
    }

    func sync(_ payload: SyncRequest) async throws -> SyncResponse {
        let wire = makeWireRequest(payload, operationID: payload.operationID)
        var request = URLRequest(url: baseURL.appendingPathComponent("sync"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(wire)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(SyncResponse.self, from: data)
    }

    private func makeWireRequest(_ payload: SyncRequest, operationID: String) -> SyncWireRequest {
        SyncWireRequest(
            contractVersion: payload.contractVersion,
            operationID: operationID,
            installationID: credential.installationID,
            apnsToken: payload.apnsToken,
            operation: payload.operation,
            cursor: payload.cursor,
            card: payload.card.map(SyncWirePersonCard.init),
            exchangeToken: payload.exchangeToken,
            exchangeMethod: payload.exchangeMethod,
            audioAssetID: payload.audioAssetID,
            audioSizeBytes: payload.audioSizeBytes,
            audioDurationMS: payload.audioDurationMS,
            moderationCategory: payload.moderationCategory,
            subjectInstallationID: payload.subjectInstallationID
        )
    }

    private static func validateConfigurationShape(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        let allowed = Set(["version", "minimumContract", "maintenance", "features", "sponsoredTemplates", "privacyURL", "supportURL", "moderationCategories", "analyticsKillSwitch"])
        if let key = object.keys.first(where: { !allowed.contains($0) }) {
            throw ClientError.unexpectedConfigurationField(key)
        }
        if let features = object["features"] as? [String: Any] {
            let featureKeys = Set(["nearbyExchange", "sponsoredTemplates", "remoteNotifications"])
            if let key = features.keys.first(where: { !featureKeys.contains($0) }) {
                throw ClientError.unexpectedConfigurationField("features.\(key)")
            }
        }
        if let templates = object["sponsoredTemplates"] as? [[String: Any]] {
            let templateKeys = Set(["id", "title", "accentHex"])
            for template in templates where template.keys.contains(where: { !templateKeys.contains($0) }) {
                let key = template.keys.first(where: { !templateKeys.contains($0) }) ?? "unknown"
                throw ClientError.unexpectedConfigurationField("sponsoredTemplates.\(key)")
            }
        }
    }
}
