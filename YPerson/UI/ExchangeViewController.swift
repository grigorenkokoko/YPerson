import Photos
import PhotosUI
import UIKit

final class ExchangeViewController: YPBaseViewController, PHPickerViewControllerDelegate {
    private let nearby: NearbyExchangeController
    private let photoScanner: PhotoCardScanner
    private let permissions: PermissionCenter
    private let apiClient: APIClient
    private let analytics: AppMetricaAnalyticsClient
    private var includePrivate = false
    private var nearbySearchAlert: UIAlertController?

    init(nearby: NearbyExchangeController, photoScanner: PhotoCardScanner, permissions: PermissionCenter, apiClient: APIClient, analytics: AppMetricaAnalyticsClient) {
        self.nearby = nearby; self.photoScanner = photoScanner; self.permissions = permissions; self.apiClient = apiClient; self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentStack.addArrangedSubview(YPStyle.label("Передайте карточку конкретному человеку. Обмен завершается только после подтверждения.", style: .body))
        addButton("Показать мой QR", "qrcode", #selector(showOwnQR), primary: true)
        addButton("Сканировать QR", "camera.viewfinder", #selector(scanQR))
        addButton("Рядом по Bluetooth", "wave.3.right", #selector(startNearby))
        addButton("Найти визитки в Фото", "photo.on.rectangle.angled", #selector(scanPhotos))
        addButton("Ввести короткий код", "number", #selector(enterCode))
        let privateSwitch = UISwitch(); privateSwitch.addTarget(self, action: #selector(togglePrivate(_:)), for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [YPStyle.label("Закрытые поля · Face ID", style: .headline), privateSwitch]); row.alignment = .center; row.distribution = .equalSpacing
        contentStack.addArrangedSubview(row)
    }

    private func addButton(_ title: String, _ symbol: String, _ action: Selector, primary: Bool = false) {
        let button = YPStyle.button(title, symbol: symbol, primary: primary); button.addTarget(self, action: action, for: .touchUpInside); contentStack.addArrangedSubview(button)
    }

    @objc private func showOwnQR() { tabBarController?.selectedIndex = 0 }

    @objc func scanQR() {
        explainPermission(title: "Сканирование QR", message: "Камера нужна, чтобы сканировать QR-код визитки YPerson и добавить человека.") { [weak self] in
            guard let self else { return }
            let scanner = QRCodeScannerViewController { [weak self] value in
                self?.analytics.report(.cardReceived("qr"))
                self?.confirmImportedCard(method: value.hasPrefix("BEGIN:VCARD") ? "vCard" : "QR")
            }
            self.navigationController?.pushViewController(scanner, animated: true)
        }
    }

    @objc private func startNearby() {
        explainPermission(title: "Обмен рядом", message: "Bluetooth нужен, чтобы находить поблизости другой iPhone с открытым экраном обмена YPerson и безопасно передавать выбранную визитку.") { [weak self] in
            self?.analytics.report(.exchangeStarted("bluetooth"))
            self?.nearby.start(onState: { [weak self] state in
                self?.handleNearbyState(state)
            }, onToken: { [weak self] token in self?.finishNearbySearch(token: token) })
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
            self?.nearby.stop()
            self?.nearbySearchAlert = nil
        })
        nearbySearchAlert = alert
        present(alert, animated: true)
        UIAccessibility.post(notification: .announcement, argument: "Идёт поиск человека рядом")
    }

    private func finishNearbySearch(token: String) {
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
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }

    private func claimNearby(token: String) {
        Task { [weak self] in
            guard let self else { return }
            let payload = SyncRequest(installationID: UIDevice.current.identifierForVendor?.uuidString ?? "simulator-installation", bearer: nil, apnsToken: nil, operation: .claimExchange, card: nil, exchangeToken: token, moderationCategory: nil)
            do {
                _ = try await apiClient.sync(payload)
                analytics.report(.cardReceived("bluetooth"))
                confirmImportedCard(method: "Bluetooth")
            } catch {
                showMessage("Обмен не подтверждён", "Не удалось связаться с сервером. Токен не сохранён; повторите обмен после восстановления сети.")
            }
        }
    }

    private func confirmImportedCard(method: String) {
        let alert = UIAlertController(title: "Карточка найдена", message: "Источник: \(method). Проверьте полученные данные перед сохранением.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Добавить человека", style: .default) { [weak self] _ in self?.showMessage("Человек добавлен", "Карточка сохранена в YPerson. В Контакты она попадёт только по отдельной команде.") })
        alert.addAction(UIAlertAction(title: "Не добавлять", style: .cancel))
        present(alert, animated: true)
    }

    private func presentPhotoResults(_ payloads: [String]) {
        guard !payloads.isEmpty else { presentPhotoFallback(); return }
        confirmImportedCard(method: "Фото · найдено кандидатов: \(payloads.count)")
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
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
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
            self?.analytics.report(.cardReceived("manual")); self?.showMessage(code.isEmpty ? "Код не введён" : "Код принят", code.isEmpty ? "Введите код или выберите другой способ." : "Проверьте полученную карточку перед сохранением.")
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
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

    deinit { nearby.stop(); photoScanner.cancel() }
}
