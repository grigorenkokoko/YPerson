import UIKit

final class PeopleViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private let makePerson: () -> UIViewController

    init(permissions: PermissionCenter, analytics: AppMetricaAnalyticsClient, makePerson: @escaping () -> UIViewController) {
        self.permissions = permissions; self.analytics = analytics; self.makePerson = makePerson
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let status = YPStyle.label("● 2 обновления визиток", style: .headline, weight: .semibold); status.textColor = YPStyle.indigo; contentStack.addArrangedSubview(status)
        let sync = YPStyle.button("Синхронизация с Контактами", symbol: "person.crop.circle.badge.checkmark", primary: true); sync.addTarget(self, action: #selector(syncContacts), for: .touchUpInside); contentStack.addArrangedSubview(sync)
        sectionTitle("Сохранённые люди")
        let alexey = YPStyle.button("Алексей Морозов · обновлено", symbol: "person.crop.circle"); alexey.contentHorizontalAlignment = .leading; alexey.addTarget(self, action: #selector(openPerson), for: .touchUpInside); contentStack.addArrangedSubview(alexey)
        let maria = YPStyle.button("Мария Орлова · актуально", symbol: "person.crop.circle"); maria.contentHorizontalAlignment = .leading; contentStack.addArrangedSubview(maria)
    }

    @objc private func openPerson() { navigationController?.pushViewController(makePerson(), animated: true) }

    @objc private func syncContacts() {
        explainPermission(title: "Синхронизация с Контактами", message: "Контакты нужны, чтобы находить дубликаты, добавлять визитки YPerson в адресную книгу и обновлять их при изменениях владельца.") { [weak self] in
            guard let self else { return }
            let continueSync: () -> Void = { [weak self] in
                guard let self else { return }
                do {
                    let duplicates = try self.permissions.duplicateContactCount(for: .sample)
                    let alert = UIAlertController(title: "План изменений", message: "Найдено совпадений: \(duplicates). Добавить тестовую карточку Алексея? Ничего не изменится без подтверждения.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Добавить", style: .default) { [weak self] _ in
                        do { try self?.permissions.saveContact(.sample); self?.analytics.report(.contactSaved); self?.showMessage("Контакт сохранён", "Изменение применено после подтверждения.") }
                        catch { self?.showMessage("Не удалось сохранить", error.localizedDescription) }
                    })
                    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); self.present(alert, animated: true)
                } catch { self.showMessage("Контакты недоступны", error.localizedDescription, settingsAction: self.permissions.openSystemSettings) }
            }
            switch self.permissions.contactsState() {
            case .authorized, .limited: continueSync()
            case .notDetermined: self.permissions.requestContacts { state in if state == .authorized(nil) || { if case .limited = state { return true }; return false }() { continueSync() } else { self.showMessage("Доступ не включён", "Карточки остаются в YPerson. Один контакт можно экспортировать системным интерфейсом.", settingsAction: self.permissions.openSystemSettings) } }
            default: self.showMessage("Доступ не включён", "Карточки остаются в YPerson. Один контакт можно экспортировать системным интерфейсом.", settingsAction: self.permissions.openSystemSettings)
            }
        }
    }
}
