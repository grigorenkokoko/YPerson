import UIKit

final class PeopleViewController: YPBaseViewController {
    private var people: [PersonCard]
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private let makePerson: (PersonCard) -> UIViewController

    init(people: [PersonCard], permissions: PermissionCenter, analytics: AppMetricaAnalyticsClient, makePerson: @escaping (PersonCard) -> UIViewController) {
        self.people = people
        self.permissions = permissions
        self.analytics = analytics
        self.makePerson = makePerson
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    func reload(people: [PersonCard]) {
        self.people = people
        guard isViewLoaded else { return }
        render()
    }

    private func render() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard !people.isEmpty else {
            contentStack.addArrangedSubview(YPStyle.label("Пока никого нет", style: .title2, weight: .bold))
            contentStack.addArrangedSubview(YPStyle.label("После подтверждённого обмена человек появится здесь. YPerson не добавляет примеры и не читает Контакты без вашей команды."))
            let exchange = YPStyle.button("Познакомиться и обменяться", symbol: "arrow.left.arrow.right", primary: true)
            exchange.addTarget(self, action: #selector(openExchange), for: .touchUpInside)
            contentStack.addArrangedSubview(exchange)
            return
        }

        let status = YPStyle.label("Сохранено людей: \(people.count)", style: .headline, weight: .semibold)
        status.textColor = YPStyle.indigo
        contentStack.addArrangedSubview(status)
        let sync = YPStyle.button("Синхронизация с Контактами", symbol: "person.crop.circle.badge.checkmark", primary: true)
        sync.addTarget(self, action: #selector(syncContacts), for: .touchUpInside)
        contentStack.addArrangedSubview(sync)
        sectionTitle("Сохранённые люди")
        for (index, person) in people.enumerated() {
            let button = YPStyle.button("\(person.name) · \(person.role)", symbol: "person.crop.circle")
            button.contentHorizontalAlignment = .leading
            button.tag = index
            button.addTarget(self, action: #selector(openPerson(_:)), for: .touchUpInside)
            contentStack.addArrangedSubview(button)
        }
    }

    @objc private func openExchange() { tabBarController?.selectedIndex = 1 }

    @objc private func openPerson(_ sender: UIButton) {
        guard people.indices.contains(sender.tag) else { return }
        navigationController?.pushViewController(makePerson(people[sender.tag]), animated: true)
    }

    @objc private func syncContacts() {
        guard let person = people.first else { return }
        explainPermission(title: "Синхронизация с Контактами", message: "Контакты нужны, чтобы находить дубликаты, добавлять визитки YPerson в адресную книгу и обновлять их при изменениях владельца.") { [weak self] in
            guard let self else { return }
            let continueSync: () -> Void = { [weak self] in
                guard let self else { return }
                do {
                    let duplicates = try self.permissions.duplicateContactCount(for: person)
                    let alert = UIAlertController(title: "План изменений", message: "Найдено совпадений: \(duplicates). Добавить карточку «\(person.name)»? Ничего не изменится без подтверждения.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Добавить", style: .default) { [weak self] _ in
                        do {
                            try self?.permissions.saveContact(person)
                            self?.analytics.report(.contactSaved)
                            self?.showMessage("Контакт сохранён", "Изменение применено после подтверждения.")
                        } catch {
                            self?.showMessage("Не удалось сохранить", error.localizedDescription)
                        }
                    })
                    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
                    self.present(alert, animated: true)
                } catch {
                    self.showMessage("Контакты недоступны", error.localizedDescription, settingsAction: self.permissions.openSystemSettings)
                }
            }
            switch self.permissions.contactsState() {
            case .authorized, .limited:
                continueSync()
            case .notDetermined:
                self.permissions.requestContacts { state in
                    if case .authorized = state { continueSync() }
                    else if case .limited = state { continueSync() }
                    else { self.showMessage("Доступ не включён", "Карточки остаются в YPerson. Один контакт можно экспортировать системным интерфейсом.", settingsAction: self.permissions.openSystemSettings) }
                }
            default:
                self.showMessage("Доступ не включён", "Карточки остаются в YPerson. Один контакт можно экспортировать системным интерфейсом.", settingsAction: self.permissions.openSystemSettings)
            }
        }
    }
}
