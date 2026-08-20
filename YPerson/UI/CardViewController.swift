import CoreImage.CIFilterBuiltins
import UIKit

final class CardViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let persistsChanges: Bool
    private let audio: AudioGreetingController
    private let imageSaver: CardImageSaver
    private let syncCoordinator: SyncCoordinator
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let makeEditor: (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController
    private let cardContent = YPStyle.stack(spacing: 16)
    private var card: PersonCard?
    private var cardView: CardSummaryView?
    private var showsPrivateFields = false
    private var preparedQRToken: String?
    private var prepareQRTask: Task<Void, Never>?
    private var prepareQRGeneration: UUID?

    var currentCard: PersonCard? { card }

    func applyPublishedCard(_ published: PersonCard) {
        card = published
        render()
    }

    func applyProfileDeletion() {
        card = nil
        showsPrivateFields = false
        render()
    }

    init(card: PersonCard?, persistsChanges: Bool, permissions: PermissionCenter, audio: AudioGreetingController, imageSaver: CardImageSaver, syncCoordinator: SyncCoordinator, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, makeEditor: @escaping (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController) {
        self.card = card
        self.persistsChanges = persistsChanges
        self.permissions = permissions
        self.audio = audio
        self.imageSaver = imageSaver
        self.syncCoordinator = syncCoordinator
        self.analytics = analytics
        self.snapshotStore = snapshotStore
        self.makeEditor = makeEditor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        prepareQRTask?.cancel()
        prepareQRTask = nil
        prepareQRGeneration = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(cardContent)
        render()
        Task { [weak self] in
            do {
                let config = try await self?.syncCoordinator.fetchConfiguration()
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
            try? snapshotStore?.writeWidgetSnapshot(.empty)
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
        try? snapshotStore?.writeWidgetSnapshot(WidgetSnapshot(updateCount: 0, isOffline: false, updatedAt: Date()))
    }

    private func makeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Сохранить изображение в Фото", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.saveImage() },
            UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareImage() }
        ])
    }

    @objc private func showQR() {
        guard let card else { return }
        let showOffline: () -> Void = { [weak self] in
            guard let self else { return }
            guard let installationID = self.syncCoordinator.installationID else {
                self.showMessage("Сначала сохраните визитку", "После сохранения YPerson создаст защищённый идентификатор для QR-кода.")
                return
            }
            let payload = ExchangePayload(
                version: 2,
                issuerInstallationID: installationID,
                card: card.exchangeCopy,
                exchangeToken: nil,
                expiresAt: nil
            )
            self.showQRCode(payload, isOffline: true)
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["YP_SCREENSHOT_STATE"] == "REVIEW_QR" {
            showOffline()
            return
        }
#endif
        prepareQRTask?.cancel()
        let generation = UUID()
        prepareQRGeneration = generation
        prepareQRTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prepareQRGeneration == generation {
                    self.prepareQRTask = nil
                    self.prepareQRGeneration = nil
                }
            }
            do {
                let token = try await self.syncCoordinator.prepareExchange(card: card, method: "qr")
                guard !Task.isCancelled, self.viewIfLoaded?.window != nil else {
                    await self.syncCoordinator.cancelExchange(token: token)
                    return
                }
                guard let installationID = self.syncCoordinator.installationID else {
                    await self.syncCoordinator.cancelExchange(token: token)
                    throw SyncCoordinator.CoordinatorError.noProfile
                }
                self.preparedQRToken = token
                self.showQRCode(ExchangePayload(
                    version: 2,
                    issuerInstallationID: installationID,
                    card: card.exchangeCopy,
                    exchangeToken: token,
                    expiresAt: Date().addingTimeInterval(10 * 60)
                ), isOffline: false)
            } catch where Task.isCancelled {
                return
            } catch {
                showOffline()
            }
        }
    }

    private func showQRCode(_ exchangePayload: ExchangePayload, isOffline: Bool) {
        guard let payload = try? ExchangePayloadCodec.encode(exchangePayload) else {
            showMessage("Не удалось создать QR", "Попробуйте ещё раз.")
            return
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let image = UIImage(ciImage: output.transformed(by: CGAffineTransform(scaleX: 9, y: 9)))
        let controller = QRExchangeViewController()
        if !isOffline, let token = exchangePayload.exchangeToken {
            controller.onClose = { [weak self] in
                guard let self, self.preparedQRToken == token else { return }
                self.preparedQRToken = nil
                Task { await self.syncCoordinator.cancelExchange(token: token) }
            }
        }
        controller.title = "Мой QR"
        controller.view.backgroundColor = YPStyle.canvas
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = "QR-код публичной визитки \(exchangePayload.card.name)"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(imageView)
        let status = YPStyle.label(
            isOffline
                ? "Офлайн-код: человек сохранит карточку на своём iPhone, но облачные обновления подключатся позже."
                : "Код действует 10 минут и подключает подтверждённые обновления карточки.",
            style: .footnote
        )
        status.textAlignment = .center
        status.accessibilityLabel = isOffline ? "Офлайн QR-код" : "Онлайн QR-код"
        status.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(status)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor, constant: -36),
            imageView.widthAnchor.constraint(equalTo: controller.view.widthAnchor, multiplier: 0.72),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
            status.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 20),
            status.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            status.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -28)
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
            guard self.persistsChanges else { return }
            Task { [weak self] in
                guard let self else { return }
                guard let response = await self.syncCoordinator.publish(updatedCard),
                      let version = response.ownCardVersion else { return }
                var published = updatedCard
                published.version = version
                self.card = published
                try? self.snapshotStore?.writeOwnCard(published)
            }
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

    deinit {
        prepareQRTask?.cancel()
        guard let token = preparedQRToken else { return }
        let coordinator = syncCoordinator
        Task { @MainActor in await coordinator.cancelExchange(token: token) }
    }
}

private final class QRExchangeViewController: UIViewController {
    var onClose: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true { onClose?() }
    }
}
