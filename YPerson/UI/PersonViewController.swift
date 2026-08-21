import UIKit

final class PersonViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let imageSaver: CardImageSaver
    private let syncCoordinator: SyncCoordinator
    private let mediaTransfer: MediaTransferClient
    private let audio: AudioGreetingController
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let contactCommitBarrier: ContactReconciliationCommitBarrier
    private var card: PersonCard
    private var summary: CardSummaryView
    private let placeLabel = YPStyle.label("Место знакомства не добавлено", style: .footnote)
    private var audioButton: UIButton?
    private var audioTask: Task<Void, Never>?
    private var moderationTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleGeneration = UUID()
    private var profileDeleted = false
    private lazy var contactReconciliation = ContactReconciliationPresenter(
        host: self,
        permissions: permissions,
        analytics: analytics,
        commitBarrier: contactCommitBarrier
    )

    init(card: PersonCard, permissions: PermissionCenter, imageSaver: CardImageSaver, syncCoordinator: SyncCoordinator, mediaTransfer: MediaTransferClient, audio: AudioGreetingController, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, contactCommitBarrier: ContactReconciliationCommitBarrier) {
        self.card = card
        self.summary = CardSummaryView(card: card, showPrivate: true)
        self.permissions = permissions; self.imageSaver = imageSaver; self.syncCoordinator = syncCoordinator; self.mediaTransfer = mediaTransfer; self.audio = audio; self.analytics = analytics; self.snapshotStore = snapshotStore; self.contactCommitBarrier = contactCommitBarrier
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = card.name
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeSafetyMenu())
        contentStack.addArrangedSubview(summary)
        if card.hasAudioGreeting, card.sourceInstallationID != nil {
            let audioButton = YPStyle.button("Воспроизвести аудиоприветствие", symbol: "waveform")
            audioButton.addTarget(self, action: #selector(playAudioGreeting), for: .touchUpInside)
            contentStack.addArrangedSubview(audioButton)
            self.audioButton = audioButton
        }
        let update = YPStyle.button("Просмотреть и обновить", symbol: "arrow.triangle.2.circlepath", primary: true); update.addTarget(self, action: #selector(reviewUpdate), for: .touchUpInside); contentStack.addArrangedSubview(update)
        sectionTitle("Контекст знакомства")
        if let meetingPlace = card.meetingPlace, !meetingPlace.isEmpty {
            placeLabel.text = "Место: \(meetingPlace) · хранится только на iPhone"
        }
        contentStack.addArrangedSubview(placeLabel)
        let location = YPStyle.button("Добавить текущее место", symbol: "location"); location.addTarget(self, action: #selector(addLocation), for: .touchUpInside); contentStack.addArrangedSubview(location)
        let contact = YPStyle.button("Сохранить в Контакты", symbol: "person.crop.circle.badge.plus"); contact.addTarget(self, action: #selector(saveContact), for: .touchUpInside); contentStack.addArrangedSubview(contact)
        let photo = YPStyle.button("Сохранить в Фото", symbol: "square.and.arrow.down"); photo.addTarget(self, action: #selector(savePhoto), for: .touchUpInside); contentStack.addArrangedSubview(photo)
    }

    private func makeSafetyMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Пожаловаться", image: UIImage(systemName: "exclamationmark.bubble")) { [weak self] _ in self?.report() },
            UIAction(title: "Заблокировать", image: UIImage(systemName: "hand.raised"), attributes: .destructive) { [weak self] _ in self?.block() },
            UIAction(title: "Удалить связь", image: UIImage(systemName: "person.crop.circle.badge.minus"), attributes: .destructive) { [weak self] _ in self?.deleteConnection() }
        ])
    }

    @objc private func reviewUpdate() {
        guard !profileDeleted else { return }
        analytics.report(.cardUpdateOpened)
        showMessage("Проверка обновлений", "Новых изменений нет. Если владелец обновит визитку, YPerson покажет разницу перед применением.")
    }

    @objc private func addLocation() {
        guard !profileDeleted else { return }
        let generation = lifecycleGeneration
        explainPermission(title: "Место знакомства", message: "Геопозиция нужна, чтобы по вашему действию сохранить место знакомства рядом с добавленным человеком.") { [weak self] in
            guard let self, self.isCurrentProfileLifecycle(generation) else { return }
            self.permissions.requestCurrentPlace { [weak self] result in
                guard let self, self.isCurrentProfileLifecycle(generation) else { return }
                switch result {
                case .success(let label):
                    self.saveMeetingPlace(label, generation: generation)
                    UIAccessibility.post(notification: .announcement, argument: "Место знакомства добавлено")
                case .failure: self.requestManualPlace(generation: generation)
                }
            }
        }
    }

    private func requestManualPlace(generation: UUID) {
        guard isCurrentProfileLifecycle(generation) else { return }
        let alert = UIAlertController(title: "Введите место вручную", message: "Координаты не требуются и никуда не отправляются.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Например, конференция в Москве" }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            guard let self, self.isCurrentProfileLifecycle(generation) else { return }
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { self.saveMeetingPlace(text, generation: generation) }
        })
        alert.addAction(UIAlertAction(title: "Пропустить", style: .cancel)); present(alert, animated: true)
    }

    @objc private func saveContact() {
        guard !profileDeleted else { return }
        contactReconciliation.start(for: card)
    }

    @objc private func savePhoto() {
        guard !profileDeleted else { return }
        imageSaver.save(imageSaver.render(summary), from: self)
    }

    @objc private func playAudioGreeting() {
        guard !profileDeleted,
              audioTask == nil,
              let peerInstallationID = card.sourceInstallationID,
              let profileContext = syncCoordinator.captureProfileOperationContext() else { return }
        let generation = lifecycleGeneration
        audioButton?.isEnabled = false
        audioButton?.configuration?.title = "Загрузка…"
        audioTask = Task { [weak self] in
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentProfileLifecycle(generation),
                  self.syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
            defer {
                if self.isCurrentProfileLifecycle(generation) {
                    self.audioTask = nil
                    self.audioButton?.isEnabled = true
                    self.audioButton?.configuration?.title = "Воспроизвести аудиоприветствие"
                }
            }
            do {
                let asset = try await self.syncCoordinator.audioAsset(
                    for: peerInstallationID,
                    context: profileContext
                )
                guard self.isCurrentProfileLifecycle(generation), !Task.isCancelled else { return }
                let fileURL = try await self.mediaTransfer.cachedAudio(for: asset) {
                    try await self.syncCoordinator.audioAsset(
                        for: peerInstallationID,
                        context: profileContext
                    )
                }
                guard self.isCurrentProfileLifecycle(generation), !Task.isCancelled else { return }
                try self.audio.play(fileURL: fileURL)
            } catch where Task.isCancelled {
                return
            } catch {
                guard self.isCurrentProfileLifecycle(generation),
                      self.syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
                self.showMessage("Не удалось воспроизвести", "Проверьте интернет и попробуйте ещё раз.")
            }
        }
    }

    private func report() {
        guard !profileDeleted else { return }
        let generation = lifecycleGeneration
        let alert = UIAlertController(title: "Пожаловаться", message: "Выберите категорию. Комментарий необязателен.", preferredStyle: .actionSheet)
        [("Нежелательная реклама", "spam"), ("Оскорбительный контент", "abusive_content"), ("Выдаёт себя за другого", "impersonation")].forEach { title, identifier in
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, self.isCurrentProfileLifecycle(generation) else { return }
                self.submitSafety(.report, category: identifier)
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func block() {
        guard !profileDeleted else { return }
        let generation = lifecycleGeneration
        let alert = UIAlertController(title: "Заблокировать «\(card.name)»?", message: "Карточка и будущие обновления будут скрыты сразу. Системный контакт не изменится.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Заблокировать", style: .destructive) { [weak self] _ in
            guard let self, self.isCurrentProfileLifecycle(generation) else { return }
            self.submitSafety(.block, category: nil)
            self.card.isBlocked = true
            self.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func deleteConnection() {
        guard !profileDeleted else { return }
        let generation = lifecycleGeneration
        let alert = UIAlertController(title: "Удалить связь?", message: "Локальная заметка удалится, а обновления прекратятся. Системный контакт останется.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            guard let self, self.isCurrentProfileLifecycle(generation) else { return }
            self.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func submitSafety(_ operation: SyncOperation, category: String?) {
        guard !profileDeleted,
              let profileContext = syncCoordinator.captureProfileOperationContext() else { return }
        guard let peerInstallationID = card.sourceInstallationID else {
            showMessage("Сохранено только локально", "Удалённое действие недоступно, пока обмен не подтверждён сервером.")
            return
        }
        let generation = lifecycleGeneration
        let taskID = UUID()
        moderationTasks[taskID] = Task { [weak self] in
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentProfileLifecycle(generation),
                  self.syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
            defer { self.moderationTasks.removeValue(forKey: taskID) }
            do {
                try await self.syncCoordinator.submitModeration(
                    operation: operation,
                    peerInstallationID: peerInstallationID,
                    category: category,
                    context: profileContext
                )
                guard self.isCurrentProfileLifecycle(generation) else { return }
                if operation == .block { self.mediaTransfer.removeAllCachedAudio() }
                self.showMessage("Отправлено", operation == .report ? "Жалоба принята. Карточку можно сразу заблокировать." : "Человек заблокирован.")
            }
            catch {
                guard self.isCurrentProfileLifecycle(generation) else { return }
                self.showMessage("Сохранено локально", "Действие будет отправлено после восстановления сети.")
            }
        }
    }

    private func saveMeetingPlace(_ place: String, generation: UUID) {
        guard isCurrentProfileLifecycle(generation) else { return }
        card.meetingPlace = place
        placeLabel.text = "Место: \(place) · хранится только на iPhone"
        try? snapshotStore?.upsertPerson(card)
    }

    func beginProfileDeletion() {
        contactReconciliation.beginProfileDeletion()
        profileDeleted = true
        lifecycleGeneration = UUID()
        audioTask?.cancel()
        audioTask = nil
        moderationTasks.values.forEach { $0.cancel() }
        moderationTasks.removeAll()
        audio.stopPlayback()
        audioButton?.isEnabled = false
        navigationController?.popToRootViewController(animated: false)
    }

    private func isCurrentProfileLifecycle(_ generation: UUID) -> Bool {
        !profileDeleted && lifecycleGeneration == generation
    }

    deinit {
        audioTask?.cancel()
        moderationTasks.values.forEach { $0.cancel() }
    }
}
