import Foundation

final class MediaTransferClient {
    enum TransferError: LocalizedError {
        case invalidAudio
        case invalidResponse
        case status(Int)

        var errorDescription: String? {
            switch self {
            case .invalidAudio: return "Аудиоприветствие не прошло проверку."
            case .invalidResponse: return "Хранилище вернуло некорректный ответ."
            case .status(let code): return "Хранилище временно недоступно (\(code))."
            }
        }
    }

    private let session: URLSession
    private let fileManager: FileManager
    private let cacheDirectory: URL

    init(session: URLSession, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YPersonAudio", isDirectory: true)
    }

    func upload(_ greeting: RecordedGreeting, to signedURL: URL) async throws {
        guard greeting.url.pathExtension.lowercased() == "m4a",
              greeting.duration > 0,
              greeting.duration <= 10,
              greeting.sizeBytes > 0,
              greeting.sizeBytes <= 1_048_576 else { throw TransferError.invalidAudio }
        var request = URLRequest(url: signedURL, timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(greeting.sizeBytes), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.upload(for: request, fromFile: greeting.url)
        try validate(response)
    }

    func cachedAudio(
        for asset: AudioAsset,
        refresh: @escaping () async throws -> AudioAsset
    ) async throws -> URL {
        let cached = cacheURL(assetID: asset.assetID)
        if isValidAudioFile(cached) { return cached }
        do {
            return try await download(asset)
        } catch TransferError.status(let status)
            where status == 401 || status == 403 || asset.expiresAt <= Date() {
            let refreshed = try await refresh()
            return try await download(refreshed)
        }
    }

    func removeCachedAudio(assetID: String) {
        try? fileManager.removeItem(at: cacheURL(assetID: assetID))
    }

    func removeAllCachedAudio() {
        try? fileManager.removeItem(at: cacheDirectory)
    }

    private func download(_ asset: AudioAsset) async throws -> URL {
        var request = URLRequest(url: asset.downloadURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransferError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TransferError.status(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased() == "audio/mp4",
              isValidAudioFile(temporaryURL, requiresM4AExtension: false) else {
            throw TransferError.invalidAudio
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheURL(assetID: asset.assetID)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw TransferError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TransferError.status(http.statusCode) }
    }

    private func isValidAudioFile(_ url: URL, requiresM4AExtension: Bool = true) -> Bool {
        guard (!requiresM4AExtension || url.pathExtension.lowercased() == "m4a"),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return false }
        return size > 0 && size <= 1_048_576
    }

    private func cacheURL(assetID: String) -> URL {
        let safeAssetID = String(assetID.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_"
        })
        return cacheDirectory.appendingPathComponent(safeAssetID).appendingPathExtension("m4a")
    }
}
