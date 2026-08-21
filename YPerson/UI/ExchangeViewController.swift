import AVFoundation
import Photos
import PhotosUI
import UIKit

final class ExchangeViewController: YPBaseViewController, PHPickerViewControllerDelegate {
    private let nearby: NearbyExchangeController
    private let photoScanner: PhotoCardScanner
    private let permissions: PermissionCenter
    private let audio: AudioGreetingController
    private let syncCoordinator: SyncCoordinator
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let ownCard: () -> PersonCard?
    private let onPersonSaved: (PersonCard) -> Void
    private let meetingPlaceSwitch = UISwitch()
    private let meetingPlaceStatus = YPStyle.label("Место не выбрано · координаты не передаются другому человеку или на сервер.", style: .footnote)
    private var includePrivate = false
    private var scannerLaunchGate = QRScannerLaunchGate()
    private var pendingMeetingPlace: String?
    private var nearbySearchAlert: UIAlertController?
    private var prepareTask: Task<Void, Never>?
    private var preparedToken: String?

    init(nearby: NearbyExchangeController, photoScanner: PhotoCardScanner, permissions: PermissionCenter, audio: AudioGreetingController, syncCoordinator: SyncCoordinator, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, ownCard: @escaping () -> PersonCard?, onPersonSaved: @escaping (PersonCard) -> Void) {
        self.nearby = nearby
        self.photoScanner = photoScanner
        self.permissions = permissions
        self.audio = audio
        self.syncCoordinator = syncCoordinator
        self.analytics = analytics
        self.snapshotStore = snapshotStore
        self.ownCard = ownCard
        self.onPersonSaved = onPersonSaved
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(YPStyle.label("Передайте карточку конкретному человеку. Обмен завершается только после подтверждения.", style: .body))
        meetingPlaceSwitch.accessibilityLabel = "Сохранить место знакомства"
        meetingPlaceSwitch.accessibilityHint = "Место сохранится только на этом iPhone после успешного обмена"
        meetingPlaceSwitch.addTarget(self, action: #selector(toggleMeetingPlace(_:)), for: .valueChanged)
        let meetingPlaceRow = UIStackView(arrangedSubviews: [YPStyle.label("Сохранить место знакомства", style: .headline), meetingPlaceSwitch])
        meetingPlaceRow.alignment = .center
        meetingPlaceRow.distribution = .equalSpacing
        contentStack.addArrangedSubview(meetingPlaceRow)
        contentStack.addArrangedSubview(meetingPlaceStatus)
        addButton("Показать мой QR", "qrcode", #selector(showOwnQR), primary: true)
        addButton("Сканировать QR", "camera.viewfinder", #selector(scanQR))
        addButton("Рядом по Bluetooth", "wave.3.right", #selector(startNearby))
        addButton("Найти визитки в Фото", "photo.on.rectangle.angled", #selector(scanPhotos))
        addButton("Ввести короткий код", "number", #selector(enterCode))
        let privateSwitch = UISwitch(); privateSwitch.addTarget(self, action: #selector(togglePrivate(_:)), for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [YPStyle.label("Закрытые поля · Face ID", style: .headline), privateSwitch]); row.alignment = .center; row.distribution = .equalSpacing
        contentStack.addArrangedSubview(row)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        prepareTask?.cancel()
        prepareTask = nil
        cancelPreparedExchange()
        nearby.stop()
        nearbySearchAlert = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if tabBarController?.selectedViewController !== navigationController {
            clearPendingMeetingPlace()
        }
    }

    private func addButton(_ title: String, _ symbol: String, _ action: Selector, primary: Bool = false) {
        let button = YPStyle.button(title, symbol: symbol, primary: primary); button.addTarget(self, action: action, for: .touchUpInside); contentStack.addArrangedSubview(button)
    }

    @objc private func toggleMeetingPlace(_ sender: UISwitch) {
        guard sender.isOn else { clearPendingMeetingPlace(); return }
        let alert = UIAlertController(
            title: "Место знакомства",
            message: "Геопозиция нужна, чтобы по вашему действию сохранить место знакомства рядом с добавленным человеком.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Продолжить", style: .default) { [weak self] _ in
            self?.requestMeetingPlace()
        })
        alert.addAction(UIAlertAction(title: "Не сейчас", style: .cancel) { [weak self] _ in
            self?.clearPendingMeetingPlace()
        })
        present(alert, animated: true)
    }

    private func requestMeetingPlace() {
        permissions.requestCurrentPlace { [weak self] result in
            switch result {
            case .success(let place):
                self?.setPendingMeetingPlace(place)
            case .failure:
                self?.requestManualMeetingPlace()
            }
        }
    }

    private func requestManualMeetingPlace() {
        let alert = UIAlertController(
            title: "Введите место вручную",
            message: "Например, название конференции или кафе. Подпись останется только на этом iPhone.",
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = "Место знакомства" }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            let place = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if place.isEmpty { self?.clearPendingMeetingPlace() }
            else { self?.setPendingMeetingPlace(place) }
        })
        alert.addAction(UIAlertAction(title: "Пропустить", style: .cancel) { [weak self] _ in
            self?.clearPendingMeetingPlace()
        })
        present(alert, animated: true)
    }

    private func setPendingMeetingPlace(_ place: String) {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clearPendingMeetingPlace(); return }
        pendingMeetingPlace = trimmed
        meetingPlaceSwitch.setOn(true, animated: true)
        meetingPlaceStatus.text = "Место: \(trimmed) · сохранится только на этом iPhone."
        UIAccessibility.post(notification: .announcement, argument: "Место знакомства выбрано: \(trimmed)")
    }

    private func clearPendingMeetingPlace() {
        pendingMeetingPlace = nil
        meetingPlaceSwitch.setOn(false, animated: true)
        meetingPlaceStatus.text = "Место не выбрано · координаты не передаются другому человеку или на сервер."
    }

    @objc private func showOwnQR() { tabBarController?.selectedIndex = 0 }

    func openScannerFromWidget() {
        let scannerIsVisible = navigationController?.topViewController
            is QRCodeScannerViewController
        let alreadyPresenting = scannerIsVisible || presentedViewController != nil
        guard scannerLaunchGate.begin(alreadyPresenting: alreadyPresenting) else {
            return
        }

        navigationController?.popToRootViewController(animated: false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scannerLaunchGate.complete()
            self.scanQR()
        }
    }

    @objc func scanQR() {
        guard presentedViewController == nil,
              !(navigationController?.topViewController is QRCodeScannerViewController) else {
            return
        }

        switch QRScannerPermissionPolicy.action(for: cameraAuthorizationState) {
        case .openScanner:
            openQRScanner()
        case .explainPermission:
            explainPermission(title: "Сканирование QR", message: "Камера нужна, чтобы сканировать QR-код визитки YPerson и добавить человека.") { [weak self] in
                self?.openQRScanner()
            }
        }
    }

    private var cameraAuthorizationState: QRScannerPermissionPolicy.AuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    private func openQRScanner() {
        let scanner = QRCodeScannerViewController { [weak self] value in
            DispatchQueue.main.async { self?.handleScannedCode(value) }
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

#if DEBUG
    func showVerificationImport() {
        confirmImportedCard(ExchangePayload(
            version: 2,
            issuerInstallationID: "00000000-0000-4000-8000-000000000001",
            card: .reviewAlexey,
            exchangeToken: nil,
            expiresAt: nil
        ))
    }
#endif

    @objc private func startNearby() {
        explainPermission(title: "Обмен рядом", message: "Bluetooth нужен, чтобы находить поблизости другой iPhone с открытым экраном обмена YPerson и безопасно передавать выбранную визитку.") { [weak self] in
            guard let self, let card = ownCard() else {
                self?.showMessage("Сначала создайте визитку", "Для обмена по Bluetooth нужна ваша сохранённая карточка.")
                return
            }
            analytics.report(.exchangeStarted("bluetooth"))
            prepareTask?.cancel()
            prepareTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let token = try await syncCoordinator.prepareExchange(
                        card: card,
                        method: "bluetooth",
                        greeting: audio.savedGreeting()
                    )
                    try Task.checkCancellation()
                    guard viewIfLoaded?.window != nil else { throw CancellationError() }
                    preparedToken = token
                    nearby.start(exchangeToken: token, onState: { [weak self] state in
                        self?.handleNearbyState(state)
                    }, onToken: { [weak self] token in self?.finishNearbySearch(token: token) })
                } catch {
                    if error is CancellationError { return }
                    nearby.stop()
                    showMessage("Не удалось начать поиск", "Для Bluetooth-обмена сейчас нужен интернет, чтобы получить короткоживущий защищённый токен. Используйте офлайн QR.")
                }
            }
        }
    }

    private func handleNearbyState(_ state: AuthorizationState) {
        switch state {
        case .authorized:
            showNearbySearch()
        case .denied:
            finishNearbySearch(title: "Bluetooth выключен", message: "QR и короткий код остаются доступны.", settingsAction: permissions.openSystemSettings)
        case .restricted:
            finishNearbySearch(title: "Bluetooth ограничен", message: "Используйте QR или короткий код.")
        case .unavailable(let message):
            finishNearbySearch(title: "Bluetooth недоступен", message: "\(message). Используйте QR или короткий код.")
        case .notDetermined, .limited:
            break
        }
    }

    private func showNearbySearch() {
        guard nearbySearchAlert == nil else { return }
        let alert = UIAlertController(
            title: "Ищем человека рядом…",
            message: "На втором iPhone откройте YPerson и также запустите «Рядом по Bluetooth».",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отменить поиск", style: .cancel) { [weak self] _ in
            self?.cancelPreparedExchange()
            self?.nearby.stop()
            self?.nearbySearchAlert = nil
            self?.clearPendingMeetingPlace()
        })
        nearbySearchAlert = alert
        present(alert, animated: true)
        UIAccessibility.post(notification: .announcement, argument: "Идёт поиск человека рядом")
    }

    private func finishNearbySearch(token: String) {
        nearby.stop()
        let alert = nearbySearchAlert
        nearbySearchAlert = nil
        guard let alert else { confirmNearby(token: token); return }
        alert.dismiss(animated: true) { [weak self] in self?.confirmNearby(token: token) }
    }

    private func finishNearbySearch(title: String, message: String, settingsAction: (() -> Void)? = nil) {
        nearby.stop()
        let alert = nearbySearchAlert
        nearbySearchAlert = nil
        let showFallback: () -> Void = { [weak self] in
            guard let self else { return }
            self.showMessage(title, message, settingsAction: settingsAction)
        }
        guard let alert else { showFallback(); return }
        alert.dismiss(animated: true, completion: showFallback)
    }

    @objc private func scanPhotos() {
        explainPermission(title: "Поиск визиток в Фото", message: "Доступ к фото нужен, чтобы по вашей команде находить сохранённые изображения визиток и импортировать людей в YPerson.") { [weak self] in
            self?.analytics.report(.exchangeStarted("photo"))
            self?.photoScanner.scan { result in
                switch result {
                case .success(let payloads): self?.presentPhotoResults(payloads)
                case .failure(let error): self?.showMessage("Не удалось просканировать Фото", error.localizedDescription)
                }
            }
        }
    }

    private func confirmNearby(token: String) {
        let alert = UIAlertController(title: "Человек найден", message: "Подтвердите обмен на обоих iPhone. До подтверждения карточка и токен не отправляются на сервер.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Подтвердить обмен", style: .default) { [weak self] _ in self?.claimNearby(token: token) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in
            self?.cancelPreparedExchange()
            self?.clearPendingMeetingPlace()
        })
        present(alert, animated: true)
    }

    private func claimNearby(token: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await claimExchange(token: token, expiresAt: nil, localCardID: nil)
                let saved = try persist(response: response, meetingPlace: pendingMeetingPlace)
                guard !saved.isEmpty else { throw ExchangeError.missingPeerCard }
                preparedToken = nil
                clearPendingMeetingPlace()
                analytics.report(.cardReceived("bluetooth"))
                showMessage("Человек добавлен", "Карточка сохранена в YPerson и связана с подтверждённым Bluetooth-обменом.")
            } catch {
                cancelPreparedExchange()
                clearPendingMeetingPlace()
                showMessage("Обмен не подтверждён", "Не удалось связаться с сервером. Токен не сохранён; повторите обмен после восстановления сети.")
            }
        }
    }

    private func handleScannedCode(_ value: String) {
        guard value.hasPrefix("yperson:v2:") else {
            showMessage("Неподдерживаемая визитка", "Сейчас надёжное локальное сохранение доступно для QR-кодов YPerson v2.")
            return
        }
        do {
            let payload = try ExchangePayloadCodec.decode(value)
            analytics.report(.cardReceived("qr"))
            confirmImportedCard(payload)
        } catch {
            showMessage("Не удалось прочитать QR", error.localizedDescription)
        }
    }

    private func confirmImportedCard(_ payload: ExchangePayload) {
        let expired = payload.expiresAt.map { $0 <= Date() } ?? false
        let hasCloudClaim = payload.exchangeToken != nil && !expired
        let cloudNote = hasCloudClaim
            ? "После сохранения YPerson попробует подключить облачные обновления."
            : "Офлайн-код: карточка сохранится только на этом iPhone без подтверждения облачной связи."
        let companyLine = payload.card.company.isEmpty ? "" : " · \(payload.card.company)"
        let alert = UIAlertController(
            title: payload.card.name,
            message: "\(payload.card.role)\(companyLine)\n\n\(cloudNote)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Добавить человека", style: .default) { [weak self] _ in
            self?.saveImportedCard(payload, allowsCloudClaim: hasCloudClaim)
        })
        alert.addAction(UIAlertAction(title: "Не добавлять", style: .cancel) { [weak self] _ in
            self?.clearPendingMeetingPlace()
        })
        present(alert, animated: true)
    }

    private func saveImportedCard(_ payload: ExchangePayload, allowsCloudClaim: Bool) {
        do {
            guard let snapshotStore else { throw ExchangeError.localStorageUnavailable }
            var localCard = payload.card.exchangeCopy
            localCard.sourceInstallationID = nil
            localCard.syncState = allowsCloudClaim ? .pending : .localOnly
            localCard.meetingPlace = pendingMeetingPlace
            try snapshotStore.upsertPerson(localCard)
            onPersonSaved(localCard)
            clearPendingMeetingPlace()
        } catch {
            showMessage("Не удалось добавить человека", "Карточка не записана на iPhone. Попробуйте ещё раз.")
            return
        }

        guard allowsCloudClaim, let token = payload.exchangeToken else {
            showMessage("Человек добавлен", "Карточка сохранена на этом iPhone. Облачная связь не подтверждалась.")
            return
        }

        showMessage("Человек добавлен", "Карточка уже сохранена на этом iPhone. Подключаем облачные обновления; при отсутствии сети это можно повторить новым кодом.")
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await claimExchange(
                    token: token,
                    expiresAt: payload.expiresAt,
                    localCardID: payload.card.id
                )
                _ = try persist(response: response)
            } catch {
                // The confirmed local card stays visible. A new short-lived code can reconnect updates.
            }
        }
    }

    @discardableResult
    private func persist(response: SyncResponse, meetingPlace: String? = nil) throws -> [PersonCard] {
        guard let snapshotStore else { throw ExchangeError.localStorageUnavailable }
        var cards = response.people.map(\.versionedCard)
        if let meetingPlace, let index = cards.indices.first {
            cards[index].meetingPlace = meetingPlace
        }
        try snapshotStore.replacePeople(cards)
        for id in response.revokedCardIDs { try snapshotStore.removePerson(id: id) }
        snapshotStore.syncCursor = response.nextCursor ?? snapshotStore.syncCursor
        let saved = snapshotStore.readPeople()
        for card in cards { onPersonSaved(card) }
        return saved.filter { card in cards.contains(where: { $0.id == card.id }) }
    }

    private func presentPhotoResults(_ payloads: [String]) {
        guard !payloads.isEmpty else { presentPhotoFallback(); return }
        guard let payload = payloads.lazy.compactMap({ try? ExchangePayloadCodec.decode($0) }).first else {
            showMessage("Визитка не распознана", "На выбранных изображениях нет поддерживаемого QR-кода YPerson v2.")
            return
        }
        confirmImportedCard(payload)
    }

    private func presentPhotoFallback() {
        let alert = UIAlertController(title: "Кандидаты не найдены", message: "Выберите одно изображение без выдачи полного доступа к медиатеке либо используйте камеру или код.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Выбрать одно фото", style: .default) { [weak self] _ in self?.presentSinglePhotoPicker() })
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            alert.addAction(UIAlertAction(title: "Изменить выбранные фото", style: .default) { [weak self] _ in guard let self else { return }; self.permissions.presentLimitedPhotoManager(from: self) })
        }
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        present(alert, animated: true)
    }

    private func presentSinglePhotoPicker() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            clearPendingMeetingPlace()
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage else { return }
            let payloads = photoScanner.scan(image: image)
            DispatchQueue.main.async { self.presentPhotoResults(payloads) }
        }
    }

    @objc private func enterCode() {
        let alert = UIAlertController(title: "Короткий код", message: "Введите код обмена", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "YP-1234"; $0.autocapitalizationType = .allCharacters }
        alert.addAction(UIAlertAction(title: "Проверить", style: .default) { [weak self, weak alert] _ in
            let code = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !code.isEmpty else {
                self?.showMessage("Код не введён", "Введите код или выберите другой способ.")
                return
            }
            self?.claimManualCode(code)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in
            self?.clearPendingMeetingPlace()
        }); present(alert, animated: true)
    }

    private func claimManualCode(_ code: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await claimExchange(token: code, expiresAt: nil, localCardID: nil)
                let saved = try persist(response: response, meetingPlace: pendingMeetingPlace)
                guard !saved.isEmpty else { throw ExchangeError.missingPeerCard }
                clearPendingMeetingPlace()
                analytics.report(.cardReceived("manual"))
                showMessage("Человек добавлен", "Карточка сохранена после подтверждения кода сервером.")
            } catch {
                clearPendingMeetingPlace()
                showMessage("Код не подтверждён", "Проверьте код и подключение к интернету.")
            }
        }
    }

    private func claimExchange(
        token: String,
        expiresAt: Date?,
        localCardID: String?
    ) async throws -> SyncResponse {
        guard let ownCard = ownCard() else { throw SyncCoordinator.CoordinatorError.noProfile }
        return try await syncCoordinator.claimExchange(
            token: token,
            expiresAt: expiresAt,
            localCardID: localCardID,
            ownCard: ownCard,
            greeting: audio.savedGreeting()
        )
    }

    @objc private func togglePrivate(_ sender: UISwitch) {
        guard sender.isOn else { includePrivate = false; return }
        explainPermission(title: "Передача закрытых полей", message: "Face ID защищает закрытые поля вашей визитки и подтверждает их передачу выбранному человеку.") { [weak self, weak sender] in
            self?.permissions.authenticatePrivateFields { result in
                let allowed = (try? result.get()) != nil; self?.includePrivate = allowed; sender?.setOn(allowed, animated: true)
                if !allowed { self?.showMessage("Оставили публичные поля", "Обмен продолжает работать без закрытых полей.") }
            }
        }
    }

    private func cancelPreparedExchange() {
        guard let token = preparedToken else { return }
        preparedToken = nil
        Task { await syncCoordinator.cancelExchange(token: token) }
    }

    deinit { prepareTask?.cancel(); nearby.stop(); photoScanner.cancel() }

    private enum ExchangeError: Error {
        case localStorageUnavailable
        case missingExchangeToken
        case missingPeerCard
    }
}
