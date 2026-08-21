import SafariServices
import UIKit
import WebKit

final class PrivacyViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let audio: AudioGreetingController
    private let analytics: AppMetricaAnalyticsClient
    private let snapshotStore: AppGroupSnapshotStore?
    private let syncCoordinator: SyncCoordinator
    private let configuration: AppConfiguration
    private let analyticsSwitch = UISwitch()
    private var lifecycleGeneration = UUID()
    private var deletionTask: Task<Void, Never>?
    private var deletionAttemptOwnership = ProfileDeletionAttemptOwnership()

    init(permissions: PermissionCenter, audio: AudioGreetingController, analytics: AppMetricaAnalyticsClient, snapshotStore: AppGroupSnapshotStore?, syncCoordinator: SyncCoordinator, configuration: AppConfiguration) {
        self.permissions = permissions; self.audio = audio; self.analytics = analytics; self.snapshotStore = snapshotStore; self.syncCoordinator = syncCoordinator; self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        sectionTitle("Данные и конфиденциальность")
        contentStack.addArrangedSubview(YPStyle.label("YPerson запрашивает доступ только после выбранной функции. Контакты, сырые фото, точное место и результат Face ID не отправляются на сервер или в аналитику.", style: .body))
        let status = YPStyle.label(permissionSummary(), style: .footnote); status.accessibilityLabel = "Статусы системных разрешений. \(permissionSummary())"; contentStack.addArrangedSubview(status)
        let settings = YPStyle.button("Открыть системные настройки", symbol: "gear"); settings.addTarget(self, action: #selector(openSettings), for: .touchUpInside); contentStack.addArrangedSubview(settings)
        sectionTitle("Уведомления и аналитика")
        let notifications = YPStyle.button("Включить обновления визиток", symbol: "bell.badge", primary: true); notifications.addTarget(self, action: #selector(enableNotifications), for: .touchUpInside); contentStack.addArrangedSubview(notifications)
        analyticsSwitch.isOn = snapshotStore?.analyticsConsent ?? false; analyticsSwitch.addTarget(self, action: #selector(changeAnalytics(_:)), for: .valueChanged)
        let analyticsRow = UIStackView(arrangedSubviews: [YPStyle.label("Аналитика AppMetrica", style: .headline), analyticsSwitch]); analyticsRow.alignment = .center; analyticsRow.distribution = .equalSpacing; contentStack.addArrangedSubview(analyticsRow)
        contentStack.addArrangedSubview(YPStyle.label("ATT управляет только рекламной атрибуцией; этот переключатель отдельно останавливает будущую отправку аналитики.", style: .footnote))
        sectionTitle("Документы и управление")
        addLink("Политика конфиденциальности", "hand.raised") { [weak self] in self?.openPolicy() }
        addLink("Поддержка и модерация", "questionmark.circle") { [weak self] in self?.openSupport() }
        let delete = YPStyle.button("Удалить профиль", symbol: "trash"); delete.configuration?.baseForegroundColor = YPStyle.destructive; delete.addTarget(self, action: #selector(deleteProfile), for: .touchUpInside); contentStack.addArrangedSubview(delete)
    }

    private func addLink(_ title: String, _ symbol: String, action: @escaping () -> Void) { let button = YPStyle.button(title, symbol: symbol); button.addAction(UIAction { _ in action() }, for: .touchUpInside); contentStack.addArrangedSubview(button) }
    private func permissionSummary() -> String { "Контакты: \(stateText(permissions.contactsState()))\nФото: доступ запрашивается в сценарии импорта\nBluetooth, камера, Face ID, место и микрофон: по действию" }
    private func stateText(_ state: AuthorizationState) -> String { switch state { case .notDetermined: return "не запрашивались"; case .authorized: return "включены"; case .limited(let note): return note ?? "ограниченный доступ"; case .denied: return "выключены"; case .restricted: return "ограничены устройством"; case .unavailable(let note): return note } }

    @objc private func openSettings() { permissions.openSystemSettings() }

    @objc private func enableNotifications() {
        explainPermission(title: "Обновления визиток", message: "Включите уведомления, чтобы узнавать об обновлениях сохранённых визиток и завершении подтверждённого обмена.") { [weak self] in
            self?.permissions.requestNotifications { state in
                if case .authorized = state { self?.permissions.scheduleReviewNotification(); self?.showMessage("Уведомления включены", "Через несколько секунд придёт локальный пример обновления карточки.") }
                else { self?.showMessage("Уведомления выключены", "Обновления остаются видны на экране «Люди».", settingsAction: self?.permissions.openSystemSettings) }
            }
        }
    }

    @objc private func changeAnalytics(_ sender: UISwitch) {
        snapshotStore?.analyticsConsent = sender.isOn; analytics.setConsent(sender.isOn)
        showMessage(sender.isOn ? "Согласие сохранено" : "Аналитика выключена", sender.isOn ? "AppMetrica может отправлять технические данные и продуктовые события без полей карточек, Контактов, медиа и точного места. IDFA используется только после отдельного разрешения ATT." : "Будущая отправка AppMetrica остановлена.")
    }

    private func openPolicy() { navigationController?.pushViewController(PolicyViewController(url: configuration.privacyPolicyURL), animated: true) }
    private func openSupport() { present(SFSafariViewController(url: configuration.supportURL), animated: true) }

    @objc private func deleteProfile() {
        guard syncCoordinator.isProfileActive else { return }
        let generation = lifecycleGeneration
        let alert = UIAlertController(title: "Удалить профиль YPerson?", message: "Будут удалены опубликованная карточка и аудиофайлы, связи, краткоживущие коды обмена, токены APNs и авторизации, а также локальные данные. Без сети запрос сохранится до подтверждения сервера. Настроенные резервные копии удаляются в течение 30 дней. Закрытая жалоба о нарушении может храниться ограниченно до 180 дней.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Удалить профиль", style: .destructive) { [weak self] _ in
            guard let self, self.lifecycleGeneration == generation,
                  self.syncCoordinator.isProfileActive else { return }
            self.performDeletion(generation: generation)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

#if DEBUG
    func showDeletionConfirmation() { deleteProfile() }
#endif

    private func performDeletion(generation: UUID) {
        guard lifecycleGeneration == generation,
              let profileContext = syncCoordinator.captureProfileOperationContext() else { return }
        deletionTask?.cancel()
        let deletionAttempt = deletionAttemptOwnership.begin()
        deletionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.deletionAttemptOwnership.finish(deletionAttempt) {
                    self.deletionTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.lifecycleGeneration == generation,
                  self.syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
            let deleted = await syncCoordinator.deleteProfile(context: profileContext)
            guard !Task.isCancelled,
                  self.deletionAttemptOwnership.acceptsOutcome(
                    for: deletionAttempt,
                    profileIsActive: self.syncCoordinator.isProfileActive
                  ) else { return }
            if deleted {
                showMessage("Профиль удалён", "Локальные данные очищены, облачная карточка и аудиофайлы отозваны. Настроенные резервные копии удаляются в течение 30 дней.")
            } else {
                showMessage("Локальные данные удалены", "Запрос на удаление облачной карточки сохранён и будет повторён при следующем запуске с сетью.")
            }
        }
    }

    func applyProfileDeletion() {
        lifecycleGeneration = UUID()
        analyticsSwitch.setOn(false, animated: false)
    }

    func applyProfileReactivation() {
        lifecycleGeneration = UUID()
        deletionAttemptOwnership.invalidateForProfileRecreation()
        deletionTask?.cancel()
        deletionTask = nil
    }

    deinit {
        deletionTask?.cancel()
    }
}

final class PolicyViewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = "Политика конфиденциальности"; webView.navigationDelegate = self; webView.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(webView); NSLayoutConstraint.activate([webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)]); webView.load(URLRequest(url: url)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Safari", style: .plain, target: self, action: #selector(openSafari)); let html = "<meta name='viewport' content='width=device-width'><body style='font: -apple-system-body; padding:24px'><h2>Политика пока не опубликована</h2><p>Это обязательный release blocker. До публикации URL приложение остаётся только тестовой сборкой.</p><p>YPerson отделяет локальные Контакты, Фото, точное место и Face ID от серверных карточек, APNs и AppMetrica.</p></body>"; webView.loadHTMLString(html, baseURL: nil) }
    @objc private func openSafari() { present(SFSafariViewController(url: url), animated: true) }
}
