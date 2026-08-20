import Photos
import UIKit
import Vision

final class PhotoCardScanner {
    private let imageManager = PHCachingImageManager()
    private var cancelled = false

    func scan(completion: @escaping (Result<[String], Error>) -> Void) {
        cancelled = false
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            self?.scanAuthorized(completion: completion)
        }
    }

    func cancel() { cancelled = true }

    func scan(image: UIImage) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .filter(ScanCandidatePolicy.isSupported)
    }

    private func scanAuthorized(completion: @escaping (Result<[String], Error>) -> Void) {
        let assets = PHAsset.fetchAssets(with: .image, options: nil)
        var payloads = Set<String>()
        let count = min(assets.count, 60)
        guard count > 0 else { DispatchQueue.main.async { completion(.success([])) }; return }
        for index in 0..<count {
            if cancelled { break }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = true
            imageManager.requestImage(for: assets.object(at: index), targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFit, options: options) { image, _ in
                guard let image else { return }
                payloads.formUnion(self.scan(image: image))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard self?.cancelled == false else { return }
            completion(.success(payloads.sorted()))
        }
    }
}
