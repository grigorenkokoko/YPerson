import Contacts
import ContactsUI
import UIKit

final class PeopleViewController: YPBaseViewController, CNContactPickerDelegate {
    private var people: [PersonCard]
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private let makePerson: (PersonCard) -> UIViewController
    private let onContactsImported: ([PersonCard]) throws -> [PersonCard]
    private lazy var contactReconciliation = ContactReconciliationPresenter(host: self, permissions: permissions, analytics: analytics)

    init(people: [PersonCard], permissions: PermissionCenter, analytics: AppMetricaAnalyticsClient, makePerson: @escaping (PersonCard) -> UIViewController, onContactsImported: @escaping ([PersonCard]) throws -> [PersonCard]) {
        self.people = people
        self.permissions = permissions
        self.analytics = analytics
        self.makePerson = makePerson
        self.onContactsImported = onContactsImported
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
            contentStack.addArrangedSubview(YPStyle.label("Добавьте выбранных людей из Контактов или познакомьтесь через обмен. YPerson не читает адресную книгу без вашей команды."))
            let importContacts = YPStyle.button("Добавить из Контактов", symbol: "person.crop.circle.badge.plus", primary: true)
            importContacts.addTarget(self, action: #selector(openContactPicker), for: .touchUpInside)
            importContacts.accessibilityHint = "Открывает системный выбор нескольких контактов"
            contentStack.addArrangedSubview(importContacts)
            let exchange = YPStyle.button("Познакомиться и обменяться", symbol: "arrow.left.arrow.right")
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
        let importContacts = YPStyle.button("Добавить из Контактов", symbol: "person.crop.circle.badge.plus")
        importContacts.addTarget(self, action: #selector(openContactPicker), for: .touchUpInside)
        importContacts.accessibilityHint = "Открывает системный выбор нескольких контактов"
        contentStack.addArrangedSubview(importContacts)
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

    @objc private func openContactPicker() {
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactMiddleNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey
        ]
        present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
        guard !contacts.isEmpty else { return }
        let cards = contacts.map(permissions.makePersonCard(from:))
        do {
            let savedPeople = try onContactsImported(cards)
            analytics.report(.cardReceived("contacts_picker"))
            reload(people: savedPeople)
            let message = cards.count == 1
                ? "Выбранный человек сохранён только в YPerson на этом iPhone."
                : "Выбранные люди сохранены только в YPerson на этом iPhone."
            showMessage("Добавлено: \(cards.count)", message)
        } catch {
            showMessage("Не удалось добавить", "Выбранные контакты не были сохранены. Попробуйте ещё раз.")
        }
    }

    @objc private func openPerson(_ sender: UIButton) {
        guard people.indices.contains(sender.tag) else { return }
        navigationController?.pushViewController(makePerson(people[sender.tag]), animated: true)
    }

    @objc private func syncContacts() {
        guard !people.isEmpty else { return }
        guard people.count > 1 else {
            contactReconciliation.start(for: people[0])
            return
        }
        let alert = UIAlertController(title: "Выберите карточку YPerson", message: "Выберите человека, которого нужно сверить с Контактами. До подтверждения ничего не изменится.", preferredStyle: .actionSheet)
        for person in people {
            let title = ContactIdentityFormatter.savedCardChoiceLabel(
                name: person.name,
                role: person.role,
                company: person.company,
                phone: person.phone,
                email: person.email
            )
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.contactReconciliation.start(for: person)
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        present(alert, animated: true)
    }
}
