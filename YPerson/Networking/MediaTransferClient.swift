import Foundation

@MainActor
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
    private var profileTransferGeneration = ProfileTransferGeneration()
    private var audioCacheGeneration = ProfileTransferGeneration()
    private var activeTransfers: [UUID: TransferHandle] = [:]

    private struct TransferHandle {
        enum Kind: Equatable {
            case upload
            case download
        }

        let kind: Kind
        let cancel: () -> Void
        let completion: Task<Void, Never>
    }

    init(session: URLSession, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YPersonAudio", isDirectory: true)
    }

    func upload(_ greeting: RecordedGreeting, to signedURL: URL) async throws {
        try Task.checkCancellation()
        guard greeting.url.pathExtension.lowercased() == "m4a",
              greeting.duration > 0,
              greeting.duration <= 10,
              greeting.sizeBytes > 0,
              greeting.sizeBytes <= 1_048_576 else { throw TransferError.invalidAudio }
        var request = URLRequest(url: signedURL, timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(greeting.sizeBytes), forHTTPHeaderField: "Content-Length")
        let generation = profileTransferGeneration.capture()
        let response = try await performUpload(request: request, fileURL: greeting.url)
        try requireCurrentProfileTransfer(generation)
        try validate(response)
    }

    func cachedAudio(
        for asset: AudioAsset,
        refresh: @escaping () async throws -> AudioAsset
    ) async throws -> URL {
        try Task.checkCancellation()
        let profileGeneration = profileTransferGeneration.capture()
        let cacheGeneration = audioCacheGeneration.capture()
        let cached = cacheURL(assetID: asset.assetID)
        if isValidAudioFile(cached) {
            try requireCurrentDownload(
                profileGeneration: profileGeneration,
                cacheGeneration: cacheGeneration
            )
            return cached
        }
        do {
            return try await download(
                asset,
                profileGeneration: profileGeneration,
                cacheGeneration: cacheGeneration
            )
        } catch TransferError.status(let status)
            where status == 401 || status == 403 || asset.expiresAt <= Date() {
            let refreshed = try await refresh()
            try requireCurrentDownload(
                profileGeneration: profileGeneration,
                cacheGeneration: cacheGeneration
            )
            return try await download(
                refreshed,
                profileGeneration: profileGeneration,
                cacheGeneration: cacheGeneration
            )
        }
    }

    func removeCachedAudio(assetID: String) {
        audioCacheGeneration.invalidate()
        activeTransfers.values.filter { $0.kind == .download }.forEach { $0.cancel() }
        try? fileManager.removeItem(at: cacheURL(assetID: assetID))
    }

    func removeAllCachedAudio() {
        audioCacheGeneration.invalidate()
        activeTransfers.values.filter { $0.kind == .download }.forEach { $0.cancel() }
        try? fileManager.removeItem(at: cacheDirectory)
    }

    func cancelAllProfileTransfersAndWait() async {
        profileTransferGeneration.invalidate()
        audioCacheGeneration.invalidate()
        let transfers = Array(activeTransfers.values)
        transfers.forEach { $0.cancel() }
        for transfer in transfers {
            await transfer.completion.value
        }
        activeTransfers.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
    }

    private func download(
        _ asset: AudioAsset,
        profileGeneration: ProfileTransferGeneration.Snapshot,
        cacheGeneration: ProfileTransferGeneration.Snapshot
    ) async throws -> URL {
        var request = URLRequest(url: asset.downloadURL, timeoutInterval: 20)
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await performDownload(request: request)
        try requireCurrentDownload(
            profileGeneration: profileGeneration,
            cacheGeneration: cacheGeneration
        )
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

    private func performUpload(request: URLRequest, fileURL: URL) async throws -> URLResponse {
        let task = Task { try await session.upload(for: request, fromFile: fileURL) }
        let id = track(task, kind: .upload)
        defer { activeTransfers.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value.1
        } onCancel: {
            task.cancel()
        }
    }

    private func performDownload(request: URLRequest) async throws -> (URL, URLResponse) {
        let task = Task { try await session.download(for: request) }
        let id = track(task, kind: .download)
        defer { activeTransfers.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func track<Success>(
        _ task: Task<Success, Error>,
        kind: TransferHandle.Kind
    ) -> UUID {
        let id = UUID()
        activeTransfers[id] = TransferHandle(
            kind: kind,
            cancel: { task.cancel() },
            completion: Task { _ = await task.result }
        )
        return id
    }

    private func requireCurrentProfileTransfer(
        _ generation: ProfileTransferGeneration.Snapshot
    ) throws {
        guard profileTransferGeneration.isCurrent(generation), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func requireCurrentDownload(
        profileGeneration: ProfileTransferGeneration.Snapshot,
        cacheGeneration: ProfileTransferGeneration.Snapshot
    ) throws {
        try requireCurrentProfileTransfer(profileGeneration)
        guard audioCacheGeneration.isCurrent(cacheGeneration) else {
            throw CancellationError()
        }
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
