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
    private let privateSwitch = UISwitch()
    private let privateStatus = YPStyle.label(
        "Телефон передаётся только через Bluetooth или ваш короткий код. QR остаётся публичным.",
        style: .footnote
    )
    private var includePrivatePhone = false
    private var nearbyCredential: ExchangeCredential?
    private var scannerLaunchGate = QRScannerLaunchGate()
    private var pendingMeetingPlace: String?
    private var nearbySearchAlert: UIAlertController?
    private var nearbyPrepareTask: Task<Void, Never>?
    private var nearbyPreparationID: UUID?
    private var shortCodePrepareTask: Task<Void, Never>?
    private var shortCodePreparationID: UUID?

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
        privateSwitch.accessibilityLabel = "Поделиться телефоном · Face ID"
        privateSwitch.accessibilityHint = "Телефон будет передан только в следующем Bluetooth-обмене или по короткому коду"
        privateSwitch.addTarget(self, action: #selector(togglePrivate(_:)), for: .valueChanged)
        let privateRow = UIStackView(arrangedSubviews: [
            YPStyle.label("Поделиться телефоном · Face ID", style: .headline),
            privateSwitch
        ])
        privateRow.alignment = .center
        privateRow.distribution = .equalSpacing
        contentStack.addArrangedSubview(privateRow)
        contentStack.addArrangedSubview(privateStatus)
        addButton("Показать мой QR", "qrcode", #selector(showOwnQR), primary: true)
        addButton("Показать короткий код", "number.square", #selector(showShortCode))
        addButton("Сканировать QR", "camera.viewfinder", #selector(scanQR))
        addButton("Рядом по Bluetooth", "wave.3.right", #selector(startNearby))
        addButton("Найти визитки в Фото", "photo.on.rectangle.angled", #selector(scanPhotos))
        addButton("Ввести короткий код", "number", #selector(enterCode))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        nearbyPrepareTask?.cancel()
        nearbyPrepareTask = nil
        nearbyPreparationID = nil
        shortCodePrepareTask?.cancel()
        shortCodePrepareTask = nil
        shortCodePreparationID = nil
        cancelNearbyExchange()
        nearby.stop()
        nearbySearchAlert = nil
        resetPrivatePhoneSharing()
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
            guard let privateSelection = selectedPrivateFields(for: card) else { return }
            analytics.report(.exchangeStarted("bluetooth"))
            nearbyPrepareTask?.cancel()
            cancelNearbyExchange()
            let preparationID = UUID()
            nearbyPreparationID = preparationID
            nearbyPrepareTask = Task { [weak self] in
                guard let self else { return }
                var preparedCredential: ExchangeCredential?
                do {
                    let prepared = try await syncCoordinator.prepareExchange(
                        card: card,
                        method: "bluetooth",
                        privateFields: privateSelection.fields,
                        greeting: audio.savedGreeting()
                    )
                    preparedCredential = prepared.credential
                    try Task.checkCancellation()
                    guard nearbyPreparationID == preparationID else { throw CancellationError() }
                    guard viewIfLoaded?.window != nil else { throw CancellationError() }
                    guard case .token(let token) = prepared.credential else {
                        throw ExchangeError.invalidPreparedCredential
                    }
                    nearbyPrepareTask = nil
                    nearbyPreparationID = nil
                    nearbyCredential = prepared.credential
                    nearby.start(exchangeToken: token, onState: { [weak self] state in
                        self?.handleNearbyState(state)
                    }, onToken: { [weak self] token in self?.finishNearbySearch(token: token) })
                } catch {
                    if let preparedCredential, nearbyCredential != preparedCredential {
                        await syncCoordinator.cancelExchange(credential: preparedCredential)
                    }
                    if error is CancellationError { return }
                    if nearbyPreparationID == preparationID {
                        nearbyPrepareTask = nil
                        nearbyPreparationID = nil
                    }
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
            self?.cancelNearbyExchange()
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
        cancelNearbyExchange()
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
            self?.cancelNearbyExchange()
            self?.clearPendingMeetingPlace()
        })
        present(alert, animated: true)
    }

    private func claimNearby(token: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await claimExchange(credential: .token(token), expiresAt: nil, localCardID: nil)
                let saved = try persist(response: response, meetingPlace: pendingMeetingPlace)
                guard !saved.isEmpty else { throw ExchangeError.missingPeerCard }
                nearbyCredential = nil
                clearPendingMeetingPlace()
                analytics.report(.cardReceived("bluetooth"))
                showMessage("Человек добавлен", "Карточка сохранена в YPerson и связана с подтверждённым Bluetooth-обменом.")
            } catch {
                cancelNearbyExchange()
                clearPendingMeetingPlace()
                showMessage("Обмен не подтверждён", "Не удалось связаться с сервером. Токен не сохранён; повторите обмен после восстановления сети.")
            }
        }
    }

    private func handleScannedCode(_ value: String) {
        if value.hasPrefix("yperson:v2:") {
            do {
                let payload = try ExchangePayloadCodec.decode(value)
                analytics.report(.cardReceived("qr"))
                confirmImportedCard(payload)
            } catch {
                showMessage("Не удалось прочитать QR", error.localizedDescription)
            }
        } else if VCardParser.isCandidate(value) {
            do {
                confirmImportedCard(try localVCardPayload(value))
            } catch {
                showMessage("Визитка vCard повреждена", error.localizedDescription)
            }
        } else {
            showMessage("Неподдерживаемая визитка", "Поддерживаются QR-коды YPerson v2 и совместимые vCard.")
        }
    }

    private func localVCardPayload(_ value: String) throws -> ExchangePayload {
        ExchangePayload(
            version: 2,
            issuerInstallationID: UUID().uuidString.lowercased(),
            card: try VCardParser.parse(value),
            exchangeToken: nil,
            expiresAt: nil
        )
    }

    private func confirmImportedCard(_ payload: ExchangePayload) {
        let expired = payload.expiresAt.map { $0 <= Date() } ?? false
        let hasCloudClaim = payload.exchangeToken != nil && !expired
        let cloudNote = hasCloudClaim
            ? "После сохранения YPerson попробует подключить облачные обновления."
            : "Офлайн-импорт: карточка сохранится только на этом iPhone без подтверждения облачной связи."
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
            let localCard = ImportedCardPersistence.card(
                from: payload,
                allowsCloudClaim: allowsCloudClaim,
                meetingPlace: pendingMeetingPlace
            )
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
                    credential: .token(token),
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
        var foundYPersonCandidate = false
        var foundVCardCandidate = false

        for value in payloads {
            if value.hasPrefix("yperson:") {
                foundYPersonCandidate = true
                if let payload = try? ExchangePayloadCodec.decode(value) {
                    confirmImportedCard(payload)
                    return
                }
            } else if VCardParser.isCandidate(value) {
                foundVCardCandidate = true
                if let payload = try? localVCardPayload(value) {
                    confirmImportedCard(payload)
                    return
                }
            }
        }

        if foundVCardCandidate {
            showMessage("Визитка vCard повреждена", "Одна или несколько vCard не содержат корректной оболочки или имени.")
        } else if foundYPersonCandidate {
            showMessage("Не удалось прочитать QR", "Одна или несколько визиток YPerson повреждены или имеют неподдерживаемую версию.")
        } else {
            showMessage("Неподдерживаемая визитка", "На выбранных изображениях нет QR-кода YPerson v2 или совместимой vCard.")
        }
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
        alert.addTextField {
            $0.placeholder = "YP-XXXX-XXXX-XXXX"
            $0.autocapitalizationType = .allCharacters
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Проверить", style: .default) { [weak self, weak alert] _ in
            let value = alert?.textFields?.first?.text ?? ""
            guard let canonicalCode = ManualExchangeCode.normalize(value) else {
                self?.showMessage("Код не подтверждён", "Введите код в формате YP-XXXX-XXXX-XXXX.")
                return
            }
            self?.claimManualCode(canonicalCode)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in
            self?.clearPendingMeetingPlace()
        }); present(alert, animated: true)
    }

    private func claimManualCode(_ code: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await claimExchange(credential: .code(code), expiresAt: nil, localCardID: nil)
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
        credential: ExchangeCredential,
        expiresAt: Date?,
        localCardID: String?
    ) async throws -> SyncResponse {
        guard let ownCard = ownCard() else { throw SyncCoordinator.CoordinatorError.noProfile }
        return try await syncCoordinator.claimExchange(
            credential: credential,
            expiresAt: expiresAt,
            localCardID: localCardID,
            ownCard: ownCard,
            greeting: audio.savedGreeting()
        )
    }

    @objc private func togglePrivate(_ sender: UISwitch) {
        guard sender.isOn else {
            resetPrivatePhoneSharing()
            return
        }
        resetPrivatePhoneSharing()
        guard let card = ownCard(), PrivateCardFields(card: card) != nil else {
            showMessage("Телефон недоступен", "В визитке пока нет телефона для передачи.")
            return
        }
        explainPermission(title: "Передача телефона", message: "Face ID или код-пароль подтверждает передачу телефона выбранному человеку через Bluetooth или короткий код. QR остаётся публичным.") { [weak self] in
            guard let self else { return }
            permissions.authenticatePrivateFields { [weak self] result in
                guard let self else { return }
                let allowed = (try? result.get()) != nil && viewIfLoaded?.window != nil
                includePrivatePhone = allowed
                privateSwitch.setOn(allowed, animated: true)
                privateStatus.text = allowed
                    ? "Телефон включён для следующего Bluetooth-обмена или короткого кода. QR остаётся публичным."
                    : "Телефон передаётся только через Bluetooth или ваш короткий код. QR остаётся публичным."
                if allowed {
                    UIAccessibility.post(notification: .announcement, argument: "Передача телефона включена")
                } else {
                    showMessage("Оставили публичные поля", "Обмен продолжает работать без телефона.")
                }
            }
        }
    }

    @objc private func showShortCode() {
        guard let card = ownCard() else {
            showMessage("Сначала создайте визитку", "Для короткого кода нужна ваша сохранённая карточка.")
            return
        }
        guard let privateSelection = selectedPrivateFields(for: card) else { return }
        analytics.report(.exchangeStarted("manual"))
        shortCodePrepareTask?.cancel()
        let preparationID = UUID()
        shortCodePreparationID = preparationID
        shortCodePrepareTask = Task { [weak self] in
            guard let self else { return }
            var preparedCredential: ExchangeCredential?
            do {
                let prepared = try await syncCoordinator.prepareExchange(
                    card: card,
                    method: "manual",
                    privateFields: privateSelection.fields,
                    greeting: audio.savedGreeting()
                )
                preparedCredential = prepared.credential
                try Task.checkCancellation()
                guard shortCodePreparationID == preparationID else { throw CancellationError() }
                guard viewIfLoaded?.window != nil else { throw CancellationError() }
                guard case .code(let code) = prepared.credential else {
                    throw ExchangeError.invalidPreparedCredential
                }
                shortCodePrepareTask = nil
                shortCodePreparationID = nil
                let coordinator = syncCoordinator
                let controller = ShortCodeViewController(
                    code: code,
                    expiresAt: prepared.expiresAt
                ) {
                    Task { await coordinator.cancelExchange(credential: .code(code)) }
                }
                if let navigationController {
                    navigationController.pushViewController(controller, animated: true)
                } else {
                    present(UINavigationController(rootViewController: controller), animated: true)
                }
            } catch {
                if let preparedCredential {
                    await syncCoordinator.cancelExchange(credential: preparedCredential)
                }
                if error is CancellationError { return }
                if shortCodePreparationID == preparationID {
                    shortCodePrepareTask = nil
                    shortCodePreparationID = nil
                }
                showMessage("Не удалось показать код", "Для короткого кода сейчас нужен интернет. Публичный QR остаётся доступен.")
            }
        }
    }

    private func selectedPrivateFields(for card: PersonCard) -> PrivateFieldsSelection? {
        guard includePrivatePhone else { return .publicOnly }
        guard let fields = PrivateCardFields(card: card) else {
            resetPrivatePhoneSharing()
            showMessage("Телефон недоступен", "В визитке пока нет телефона для передачи.")
            return nil
        }
        return .phone(fields)
    }

    private func resetPrivatePhoneSharing() {
        includePrivatePhone = false
        privateSwitch.setOn(false, animated: true)
        privateStatus.text = "Телефон передаётся только через Bluetooth или ваш короткий код. QR остаётся публичным."
    }

    private func cancelNearbyExchange() {
        guard let credential = nearbyCredential else { return }
        nearbyCredential = nil
        Task { await syncCoordinator.cancelExchange(credential: credential) }
    }

    deinit {
        nearbyPrepareTask?.cancel()
        shortCodePrepareTask?.cancel()
        nearby.stop()
        photoScanner.cancel()
    }

    private enum ExchangeError: Error {
        case localStorageUnavailable
        case invalidPreparedCredential
        case missingPeerCard
    }

    private enum PrivateFieldsSelection {
        case publicOnly
        case phone(PrivateCardFields)

        var fields: PrivateCardFields? {
            if case .phone(let fields) = self { return fields }
            return nil
        }
    }
}
