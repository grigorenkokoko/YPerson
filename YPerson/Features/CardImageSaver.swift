import Photos
import UIKit

final class CardImageSaver {
    func render(_ view: UIView) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { context in view.layer.render(in: context.cgContext) }
    }

    func save(_ image: UIImage, from viewController: UIViewController) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.alert("Не удалось сохранить", "Доступ к добавлению в Фото выключен. Используйте системное меню «Поделиться».", from: viewController) }
                return
            }
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: image) }) { success, error in
                DispatchQueue.main.async {
                    if success { self.alert("Сохранено", "Изображение визитки добавлено в Фото.", from: viewController) }
                    else { self.alert("Не удалось сохранить", error?.localizedDescription ?? "Попробуйте системное меню «Поделиться».", from: viewController) }
                }
            }
        }
    }

    func share(_ image: UIImage, from viewController: UIViewController, sourceView: UIView) {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = sourceView
        viewController.present(controller, animated: true)
    }

    private func alert(_ title: String, _ message: String, from viewController: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        viewController.present(alert, animated: true)
    }
}
