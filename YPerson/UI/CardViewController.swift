import CoreImage.CIFilterBuiltins
import UIKit

final class CardViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let audio: AudioGreetingController
    private let imageSaver: CardImageSaver
    private let apiClient: APIClient
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let makeEditor: () -> UIViewController
    private var cardView = CardSummaryView(card: .own)

    init(permissions: PermissionCenter, audio: AudioGreetingController, imageSaver: CardImageSaver, apiClient: APIClient, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, makeEditor: @escaping () -> UIViewController) {
        self.permissions = permissions
        self.audio = audio
        self.imageSaver = imageSaver
        self.apiClient = apiClient
        self.analytics = analytics
        self.snapshotStore = snapshotStore
        self.makeEditor = makeEditor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
        let sync = YPStyle.label("● Синхронизировано · локальные данные защищены", style: .footnote, weight: .semibold)
        sync.textColor = YPStyle.ink
        sync.accessibilityLabel = "Синхронизировано. Локальные данные защищены."
        contentStack.addArrangedSubview(sync)
        contentStack.addArrangedSubview(cardView)
        let qr = YPStyle.button("Показать QR", symbol: "qrcode", primary: true)
        qr.addTarget(self, action: #selector(showQR), for: .touchUpInside)
        contentStack.addArrangedSubview(qr)
        let edit = YPStyle.button("Изменить карточку", symbol: "pencil")
        edit.addTarget(self, action: #selector(editCard), for: .touchUpInside)
        contentStack.addArrangedSubview(edit)
        let unlock = YPStyle.button("Открыть закрытые поля", symbol: "faceid")
        unlock.addTarget(self, action: #selector(unlockPrivate), for: .touchUpInside)
        contentStack.addArrangedSubview(unlock)
        let greeting = YPStyle.button("Аудиоприветствие · ▶ 08 с", symbol: "waveform")
        greeting.addTarget(self, action: #selector(playGreeting), for: .touchUpInside)
        contentStack.addArrangedSubview(greeting)
        Task { [weak self, weak sync] in
            do {
                let config = try await self?.apiClient.fetchConfiguration()
                if let config {
                    self?.analytics.setRemoteKillSwitch(config.analyticsKillSwitch)
                    if config.minimumContract > 1 { sync?.text = "⚠ Требуется обновление · карточка доступна офлайн" }
                    else if config.maintenance { sync?.text = "⚠ Технические работы · карточка доступна офлайн" }
                }
            } catch { sync?.text = "○ Без сети · изменения будут отправлены позже" }
        }
        try? snapshotStore?.writeWidgetSnapshot(WidgetSnapshot(updateCount: 2, isOffline: false, updatedAt: Date()))
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Сохранить изображение в Фото", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.saveImage() },
            UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareImage() }
        ])
    }

    @objc private func showQR() {
        let data = "yperson:card:person-anna:review-token".data(using: .utf8)!
        let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let image = UIImage(ciImage: output.transformed(by: CGAffineTransform(scaleX: 9, y: 9)))
        let controller = UIViewController(); controller.title = "Мой QR"; controller.view.backgroundColor = YPStyle.canvas
        let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit; imageView.accessibilityLabel = "QR-код публичной визитки Анны Смирновой"; imageView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(imageView)
        NSLayoutConstraint.activate([imageView.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), imageView.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor), imageView.widthAnchor.constraint(equalTo: controller.view.widthAnchor, multiplier: 0.72), imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor)])
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func editCard() { navigationController?.pushViewController(makeEditor(), animated: true) }

    @objc private func unlockPrivate() {
        explainPermission(title: "Закрытые поля", message: "Face ID защищает закрытые поля вашей визитки и подтверждает их передачу выбранному человеку.") { [weak self] in
            self?.permissions.authenticatePrivateFields { result in
                guard let self else { return }
                if case .success = result {
                    let replacement = CardSummaryView(card: .own, showPrivate: true)
                    self.contentStack.insertArrangedSubview(replacement, at: 1)
                    self.cardView.removeFromSuperview(); self.cardView = replacement
                    UIAccessibility.post(notification: .announcement, argument: "Закрытые поля открыты")
                } else { self.showMessage("Поля остались закрыты", "Публичная карточка по-прежнему доступна.") }
            }
        }
    }

    @objc private func playGreeting() { audio.play() }
    private func saveImage() { imageSaver.save(imageSaver.render(cardView), from: self) }
    private func shareImage() { imageSaver.share(imageSaver.render(cardView), from: self, sourceView: cardView) }

#if DEBUG
    func showVerificationQR() { showQR() }
#endif
}
