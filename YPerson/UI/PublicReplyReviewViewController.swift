import UIKit

final class PublicReplyReviewViewController: UIViewController {
    private let reply: PublicContactReply
    private let onAccept: (PersonCard) -> Void
    private let onLater: () -> Void

    init(
        reply: PublicContactReply,
        onAccept: @escaping (PersonCard) -> Void,
        onLater: @escaping () -> Void
    ) {
        self.reply = reply
        self.onAccept = onAccept
        self.onLater = onLater
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = YPStyle.canvas
        sheetPresentationController?.detents = [.medium(), .large()]
        sheetPresentationController?.prefersGrabberVisible = false

        let title = YPStyle.label("Новый человек", style: .title2, weight: .bold)
        title.textAlignment = .center

        let monogram = YPStyle.label(initials, style: .largeTitle, weight: .bold)
        monogram.textAlignment = .center
        monogram.textColor = YPStyle.indigo
        monogram.backgroundColor = YPStyle.surface
        monogram.layer.cornerRadius = 40
        monogram.layer.masksToBounds = true
        monogram.adjustsFontSizeToFitWidth = true
        monogram.minimumScaleFactor = 0.5
        monogram.translatesAutoresizingMaskIntoConstraints = false
        monogram.heightAnchor.constraint(equalToConstant: 80).isActive = true
        monogram.widthAnchor.constraint(equalToConstant: 80).isActive = true
        monogram.isAccessibilityElement = true
        monogram.accessibilityLabel = "Инициалы: \(initials)"

        let monogramContainer = UIView()
        monogramContainer.addSubview(monogram)
        NSLayoutConstraint.activate([
            monogram.centerXAnchor.constraint(equalTo: monogramContainer.centerXAnchor),
            monogram.topAnchor.constraint(equalTo: monogramContainer.topAnchor),
            monogram.bottomAnchor.constraint(equalTo: monogramContainer.bottomAnchor)
        ])

        let name = YPStyle.label(reply.name, style: .title3, weight: .semibold)
        name.textAlignment = .center

        let contact = YPStyle.label(contactDescription, style: .body)
        contact.textAlignment = .center
        contact.accessibilityLabel = contactDescription

        let add = YPStyle.button("Добавить человека", symbol: "person.badge.plus", primary: true)
        add.addTarget(self, action: #selector(acceptReply), for: .touchUpInside)
        add.accessibilityHint = "Сохраняет человека только в YPerson на этом iPhone"

        let later = YPStyle.button("Позже", symbol: "clock")
        later.addTarget(self, action: #selector(reviewLater), for: .touchUpInside)
        later.accessibilityHint = "Оставляет ответ ожидающим"

        let stack = UIStackView(arrangedSubviews: [title, monogramContainer, name, contact, add, later])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    func showSaveFailure() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Не удалось добавить человека",
            message: "Карточка не записана на iPhone. Попробуйте ещё раз.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private var trimmedEmail: String? {
        reply.email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var trimmedPhone: String? {
        reply.phone?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private var contactDescription: String {
        if let email = trimmedEmail { return "Электронная почта: \(email)" }
        if let phone = trimmedPhone { return "Телефон: \(phone)" }
        return "Контакт не указан"
    }

    private var initials: String {
        let characters = reply.name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)
        let result = characters.map(String.init).joined().uppercased()
        return result.isEmpty ? "?" : result
    }

    @objc private func acceptReply() {
        let email = trimmedEmail
        let phone = email == nil ? trimmedPhone : nil
        onAccept(PersonCard(
            id: "public-reply-\(reply.id)",
            name: reply.name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: "",
            company: "",
            phone: phone ?? "",
            email: email ?? "",
            tagline: "",
            hasAudioGreeting: false,
            meetingPlace: nil,
            isBlocked: false,
            templateID: CardTemplateCatalog.standardClean.id,
            version: 1,
            sourceInstallationID: nil,
            syncState: .localOnly
        ))
    }

    @objc private func reviewLater() { onLater() }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
