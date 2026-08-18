import ContactsUI
import UIKit

final class PersonViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let imageSaver: CardImageSaver
    private let apiClient: APIClient
    private let analytics: AppMetricaAnalyticsClient
    private var card: PersonCard
    private var summary: CardSummaryView
    private let placeLabel = YPStyle.label("Место знакомства не добавлено", style: .footnote)

    init(card: PersonCard, permissions: PermissionCenter, imageSaver: CardImageSaver, apiClient: APIClient, analytics: AppMetricaAnalyticsClient) {
        self.card = card
        self.summary = CardSummaryView(card: card, showPrivate: true)
        self.permissions = permissions; self.imageSaver = imageSaver; self.apiClient = apiClient; self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = card.name
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeSafetyMenu())
        contentStack.addArrangedSubview(summary)
        let update = YPStyle.button("Просмотреть и обновить", symbol: "arrow.triangle.2.circlepath", primary: true); update.addTarget(self, action: #selector(reviewUpdate), for: .touchUpInside); contentStack.addArrangedSubview(update)
        sectionTitle("Контекст знакомства")
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

    @objc private func reviewUpdate() { analytics.report(.cardUpdateOpened); showMessage("Проверка обновлений", "Новых изменений нет. Если владелец обновит визитку, YPerson покажет разницу перед применением.") }

    @objc private func addLocation() {
        explainPermission(title: "Место знакомства", message: "Геопозиция нужна, чтобы по вашему действию сохранить место знакомства рядом с добавленным человеком.") { [weak self] in
            self?.permissions.requestCurrentPlace { result in
                switch result {
                case .success(let label): self?.card.meetingPlace = label; self?.placeLabel.text = "Место: \(label) · хранится только на iPhone"; UIAccessibility.post(notification: .announcement, argument: "Место знакомства добавлено")
                case .failure: self?.requestManualPlace()
                }
            }
        }
    }

    private func requestManualPlace() {
        let alert = UIAlertController(title: "Введите место вручную", message: "Координаты не требуются и никуда не отправляются.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Например, конференция в Москве" }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { self?.card.meetingPlace = text; self?.placeLabel.text = "Место: \(text) · хранится только на iPhone" }
        })
        alert.addAction(UIAlertAction(title: "Пропустить", style: .cancel)); present(alert, animated: true)
    }

    @objc private func saveContact() {
        explainPermission(title: "Сохранение в Контакты", message: "Контакты нужны, чтобы находить дубликаты, добавлять визитки YPerson в адресную книгу и обновлять их при изменениях владельца.") { [weak self] in
            guard let self else { return }
            let save: () -> Void = { [weak self] in
                guard let self else { return }
                do { try self.permissions.saveContact(self.card); self.analytics.report(.contactSaved); self.showMessage("Сохранено", "Карточка добавлена в Контакты.") }
                catch { self.showMessage("Не удалось сохранить", error.localizedDescription) }
            }
            switch self.permissions.contactsState() {
            case .authorized, .limited: save()
            case .notDetermined: self.permissions.requestContacts { state in if case .authorized = state { save() } else if case .limited = state { save() } else { self.offerSystemContactFallback() } }
            default: self.offerSystemContactFallback()
            }
        }
    }

    private func offerSystemContactFallback() {
        let alert = UIAlertController(title: "Контакты недоступны", message: "Карточка остаётся в YPerson. Можно открыть системную форму одного контакта без чтения адресной книги.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Открыть форму", style: .default) { [weak self] _ in
            guard let self else { return }
            let controller = CNContactViewController(forNewContact: self.permissions.makeContact(self.card))
            self.navigationController?.pushViewController(controller, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Настройки", style: .default) { [weak self] _ in self?.permissions.openSystemSettings() })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func savePhoto() { imageSaver.save(imageSaver.render(summary), from: self) }

    private func report() {
        let alert = UIAlertController(title: "Пожаловаться", message: "Выберите категорию. Комментарий необязателен.", preferredStyle: .actionSheet)
        [("Нежелательная реклама", "spam"), ("Оскорбительный контент", "abusive_content"), ("Выдаёт себя за другого", "impersonation")].forEach { title, identifier in
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.submitSafety(.report, category: identifier) })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func block() {
        let alert = UIAlertController(title: "Заблокировать «\(card.name)»?", message: "Карточка и будущие обновления будут скрыты сразу. Системный контакт не изменится.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Заблокировать", style: .destructive) { [weak self] _ in self?.submitSafety(.block, category: nil); self?.card.isBlocked = true; self?.navigationController?.popViewController(animated: true) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func deleteConnection() {
        let alert = UIAlertController(title: "Удалить связь?", message: "Локальная заметка удалится, а обновления прекратятся. Системный контакт останется.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); present(alert, animated: true)
    }

    private func submitSafety(_ operation: SyncOperation, category: String?) {
        Task { [weak self] in
            guard let self else { return }
            let request = SyncRequest(installationID: UIDevice.current.identifierForVendor?.uuidString ?? "simulator-installation", bearer: nil, apnsToken: nil, operation: operation, card: nil, exchangeToken: nil, moderationCategory: category)
            do { _ = try await self.apiClient.sync(request); self.showMessage("Отправлено", operation == .report ? "Жалоба принята. Карточку можно сразу заблокировать." : "Человек заблокирован.") }
            catch { self.showMessage("Сохранено локально", "Действие будет отправлено после восстановления сети.") }
        }
    }
}
