import CoreImage.CIFilterBuiltins
import UIKit

final class CardViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let persistsChanges: Bool
    private let audio: AudioGreetingController
    private let imageSaver: CardImageSaver
    private let apiClient: APIClient
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let makeEditor: (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController
    private let cardContent = YPStyle.stack(spacing: 16)
    private var card: PersonCard?
    private var cardView: CardSummaryView?
    private var showsPrivateFields = false

    init(card: PersonCard?, persistsChanges: Bool, permissions: PermissionCenter, audio: AudioGreetingController, imageSaver: CardImageSaver, apiClient: APIClient, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, makeEditor: @escaping (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController) {
        self.card = card
        self.persistsChanges = persistsChanges
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
        contentStack.addArrangedSubview(cardContent)
        render()
        Task { [weak self] in
            do {
                let config = try await self?.apiClient.fetchConfiguration()
                if let config { self?.analytics.setRemoteKillSwitch(config.analyticsKillSwitch) }
            } catch {
                // The card remains available from local storage when configuration is offline.
            }
        }
    }

    private func render() {
        cardContent.arrangedSubviews.forEach {
            cardContent.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let card else {
            navigationItem.rightBarButtonItem = nil
            cardView = nil
            cardContent.addArrangedSubview(YPStyle.label("Создайте цифровую визитку", style: .title2, weight: .bold))
            cardContent.addArrangedSubview(YPStyle.label("Добавьте своё имя и рабочие данные. Они сохранятся на этом iPhone и появятся здесь после вашего подтверждения."))
            let create = YPStyle.button("Создать визитку", symbol: "person.crop.rectangle.badge.plus", primary: true)
            create.addTarget(self, action: #selector(editCard), for: .touchUpInside)
            cardContent.addArrangedSubview(create)
            return
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
        let sync = YPStyle.label("● Сохранено на этом iPhone", style: .footnote, weight: .semibold)
        sync.textColor = YPStyle.ink
        sync.accessibilityLabel = "Визитка сохранена на этом iPhone."
        cardContent.addArrangedSubview(sync)

        let summary = CardSummaryView(card: card, showPrivate: showsPrivateFields)
        cardView = summary
        cardContent.addArrangedSubview(summary)

        let qr = YPStyle.button("Показать QR", symbol: "qrcode", primary: true)
        qr.addTarget(self, action: #selector(showQR), for: .touchUpInside)
        cardContent.addArrangedSubview(qr)
        let edit = YPStyle.button("Изменить карточку", symbol: "pencil")
        edit.addTarget(self, action: #selector(editCard), for: .touchUpInside)
        cardContent.addArrangedSubview(edit)
        let unlock = YPStyle.button("Открыть закрытые поля", symbol: "faceid")
        unlock.addTarget(self, action: #selector(unlockPrivate), for: .touchUpInside)
        cardContent.addArrangedSubview(unlock)
        if card.hasAudioGreeting {
            let greeting = YPStyle.button("Аудиоприветствие", symbol: "waveform")
            greeting.addTarget(self, action: #selector(playGreeting), for: .touchUpInside)
            cardContent.addArrangedSubview(greeting)
        }
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Сохранить изображение в Фото", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.saveImage() },
            UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareImage() }
        ])
    }

    @objc private func showQR() {
        guard let card else { return }
        var payload = "yperson:card:\(card.id)"
#if DEBUG
        if ProcessInfo.processInfo.environment["YP_SCREENSHOT_STATE"] != nil {
            payload += ":review-token"
        }
#endif
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let image = UIImage(ciImage: output.transformed(by: CGAffineTransform(scaleX: 9, y: 9)))
        let controller = UIViewController()
        controller.title = "Мой QR"
        controller.view.backgroundColor = YPStyle.canvas
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = "QR-код публичной визитки \(card.name)"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: controller.view.widthAnchor, multiplier: 0.72),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor)
        ])
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func editCard() {
        let editor = makeEditor(card) { [weak self] updatedCard in
            guard let self else { return }
            let isNew = self.card == nil
            self.card = updatedCard
            self.showsPrivateFields = false
            if self.persistsChanges { try? self.snapshotStore?.writeOwnCard(updatedCard) }
            if isNew { self.analytics.report(.cardCreated) }
            self.render()
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    @objc private func unlockPrivate() {
        guard card != nil else { return }
        explainPermission(title: "Закрытые поля", message: "Face ID защищает закрытые поля вашей визитки и подтверждает их передачу выбранному человеку.") { [weak self] in
            self?.permissions.authenticatePrivateFields { result in
                guard let self else { return }
                if case .success = result {
                    self.showsPrivateFields = true
                    self.render()
                    UIAccessibility.post(notification: .announcement, argument: "Закрытые поля открыты")
                } else {
                    self.showMessage("Поля остались закрыты", "Публичная карточка по-прежнему доступна.")
                }
            }
        }
    }

    @objc private func playGreeting() { audio.play() }

    private func saveImage() {
        guard let cardView else { return }
        imageSaver.save(imageSaver.render(cardView), from: self)
    }

    private func shareImage() {
        guard let cardView else { return }
        imageSaver.share(imageSaver.render(cardView), from: self, sourceView: cardView)
    }

#if DEBUG
    func showVerificationQR() { showQR() }
#endif
}
