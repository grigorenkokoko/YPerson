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
    private let makeEditor: (PersonCard?, @escaping (PersonCard) throws -> Void) -> UIViewController
    private let cardContent = YPStyle.stack(spacing: 16)
    private var card: PersonCard?
    private var cardView: CardSummaryView?
    private var showsPrivateFields = false
    private var prepareQRTask: Task<Void, Never>?
    private var prepareQRGeneration: UUID?
    private weak var publicLinkLoadingAlert: UIAlertController?

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

    init(card: PersonCard?, persistsChanges: Bool, permissions: PermissionCenter, audio: AudioGreetingController, imageSaver: CardImageSaver, syncCoordinator: SyncCoordinator, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, makeEditor: @escaping (PersonCard?, @escaping (PersonCard) throws -> Void) -> UIViewController) {
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
#if DEBUG
        if ProcessInfo.processInfo.environment["YP_SCREENSHOT_STATE"] == "REVIEW_QR" {
            showOfflineYPersonQR()
            return
        }
#endif
        prepareQRTask?.cancel()
        publicLinkLoadingAlert?.dismiss(animated: false)
        let generation = UUID()
        prepareQRGeneration = generation
        let loading = UIAlertController(
            title: "Создаём универсальную ссылку…",
            message: "QR откроется обычной камерой.",
            preferredStyle: .alert
        )
        publicLinkLoadingAlert = loading
        present(loading, animated: true)
        prepareQRTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await syncCoordinator.activatePublicLink(card: card)
                try Task.checkCancellation()
                finishPublicLinkActivation(generation: generation) { [weak self] in
                    self?.showUniversalQRCode(url: url, card: card)
                }
            } catch {
                guard !Task.isCancelled else {
                    finishPublicLinkActivation(generation: generation) {}
                    return
                }
                finishPublicLinkActivation(generation: generation) { [weak self] in
                    self?.showPublicLinkFailure()
                }
            }
        }
    }

    private func finishPublicLinkActivation(
        generation: UUID,
        completion: @escaping () -> Void
    ) {
        guard prepareQRGeneration == generation else { return }
        prepareQRTask = nil
        prepareQRGeneration = nil
        let loading = publicLinkLoadingAlert
        publicLinkLoadingAlert = nil
        if loading?.presentingViewController != nil {
            loading?.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    private func showPublicLinkFailure() {
        let alert = UIAlertController(
            title: "Не удалось создать универсальную ссылку",
            message: "Проверьте подключение к интернету или используйте локальный QR-код YPerson.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Показать офлайн-код YPerson", style: .default) { [weak self] _ in
            self?.showOfflineYPersonQR()
        })
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        present(alert, animated: true)
    }

    private func showUniversalQRCode(url: URL, card: PersonCard) {
        guard let image = qrCodeImage(for: url.absoluteString) else {
            showMessage("Не удалось создать QR", "Попробуйте ещё раз.")
            return
        }
        let controller = UniversalQRViewController(
            image: image,
            cardName: card.name,
            onShare: { [weak self] sourceView in
                guard let self else { return }
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = sourceView
                share.popoverPresentationController?.sourceRect = sourceView.bounds
                self.navigationController?.topViewController?.present(share, animated: true)
            },
            onRevoke: { [weak self] controller in
                self?.confirmPublicLinkRevocation(from: controller)
            }
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func confirmPublicLinkRevocation(from controller: UIViewController) {
        let alert = UIAlertController(
            title: "Отозвать ссылку?",
            message: "Этот универсальный QR и ранее отправленная ссылка перестанут открывать визитку.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отозвать ссылку", style: .destructive) { [weak self, weak controller] _ in
            guard let self else { return }
            Task { [weak self, weak controller] in
                guard let self, let controller else { return }
                if await syncCoordinator.revokePublicLink() {
                    controller.navigationController?.popViewController(animated: true)
                } else {
                    let error = UIAlertController(
                        title: "Не удалось отозвать ссылку",
                        message: "Ссылка могла остаться активной. Проверьте интернет и повторите попытку.",
                        preferredStyle: .alert
                    )
                    error.addAction(UIAlertAction(title: "OK", style: .cancel))
                    controller.present(error, animated: true)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        controller.present(alert, animated: true)
    }

    private func showOfflineYPersonQR() {
        guard let card else { return }
        guard let installationID = syncCoordinator.installationID else {
            showMessage("Сначала сохраните визитку", "После сохранения YPerson создаст защищённый идентификатор для QR-кода.")
            return
        }
        showOfflineYPersonQRCode(ExchangePayload(
            version: 2,
            issuerInstallationID: installationID,
            card: card.exchangeCopy,
            exchangeToken: nil,
            expiresAt: nil
        ))
    }

    private func showOfflineYPersonQRCode(_ exchangePayload: ExchangePayload) {
        guard let payload = try? ExchangePayloadCodec.encode(exchangePayload) else {
            showMessage("Не удалось создать QR", "Попробуйте ещё раз.")
            return
        }
        guard let image = qrCodeImage(for: payload) else { return }
        let controller = QRExchangeViewController()
        controller.title = "Офлайн-обмен YPerson"
        controller.view.backgroundColor = YPStyle.canvas
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = "Офлайн QR-код YPerson для визитки \(exchangePayload.card.name)"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(imageView)
        let status = YPStyle.label(
            "Офлайн-код YPerson: человек сохранит карточку на своём iPhone без универсальной ссылки.",
            style: .footnote
        )
        status.textAlignment = .center
        status.accessibilityLabel = "Офлайн QR-код YPerson"
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

    private func qrCodeImage(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return UIImage(ciImage: output.transformed(by: CGAffineTransform(scaleX: 9, y: 9)))
    }

    @objc private func editCard() {
        let editor = makeEditor(card) { [weak self] updatedCard in
            guard let self else { return }
            let isNew = self.card == nil
            if self.persistsChanges {
                guard let snapshotStore = self.snapshotStore else {
                    throw CardSaveError.localStorageUnavailable
                }
                try snapshotStore.writeOwnCard(updatedCard)
            }
            self.card = updatedCard
            self.showsPrivateFields = false
            if isNew { self.analytics.report(.cardCreated) }
            self.render()
            guard self.persistsChanges else { return }
            Task { [weak self] in
                guard let self else { return }
                guard let response = await self.syncCoordinator.publish(
                    updatedCard,
                    greeting: self.audio.savedGreeting()
                ) else {
                    self.showMessage(
                        "Карточка сохранена на iPhone",
                        "Онлайн-версия пока не обновлена. Повторите сохранение позже."
                    )
                    return
                }
                guard let version = response.ownCardVersion else { return }
                var published = updatedCard
                published.version = version
                self.card = published
                do {
                    try self.snapshotStore?.writeOwnCard(published)
                } catch {
                    self.showMessage(
                        "Онлайн-версия обновлена",
                        "Не удалось сохранить её номер на iPhone. Повторите сохранение карточки."
                    )
                }
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
    }
}

private enum CardSaveError: Error {
    case localStorageUnavailable
}

private final class QRExchangeViewController: UIViewController {
}

private final class UniversalQRViewController: UIViewController {
    private let onShare: (UIView) -> Void
    private let onRevoke: (UIViewController) -> Void

    init(
        image: UIImage,
        cardName: String,
        onShare: @escaping (UIView) -> Void,
        onRevoke: @escaping (UIViewController) -> Void
    ) {
        self.onShare = onShare
        self.onRevoke = onRevoke
        super.init(nibName: nil, bundle: nil)
        title = "Универсальный QR"
        view.backgroundColor = YPStyle.canvas

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityLabel = "Универсальный QR-код публичной визитки \(cardName)"

        let note = YPStyle.label(
            "Откроется обычной камерой. YPerson собеседнику не нужен.",
            style: .body,
            weight: .semibold
        )
        note.textAlignment = .center

        let share = YPStyle.button("Поделиться ссылкой", symbol: "square.and.arrow.up", primary: true)
        share.addTarget(self, action: #selector(shareLink(_:)), for: .touchUpInside)
        share.accessibilityHint = "Открывает системное меню отправки ссылки"

        let revoke = YPStyle.button("Отозвать ссылку", symbol: "link.badge.minus")
        revoke.configuration?.baseForegroundColor = YPStyle.destructive
        revoke.addTarget(self, action: #selector(revokeLink), for: .touchUpInside)
        revoke.accessibilityHint = "Потребуется подтверждение"

        let stack = UIStackView(arrangedSubviews: [imageView, note, share, revoke])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor)
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func shareLink(_ sender: UIButton) { onShare(sender) }
    @objc private func revokeLink() { onRevoke(self) }
}
