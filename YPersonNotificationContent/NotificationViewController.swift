import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let nameLabel = UILabel()
    private let changesLabel = UILabel()
    private let reviewButton = UIButton(type: .system)
    private let blockButton = UIButton(type: .system)
    private var awaitingBlockConfirmation = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let avatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill")); avatar.tintColor = .systemIndigo; avatar.contentMode = .scaleAspectFit; avatar.widthAnchor.constraint(equalToConstant: 48).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 48).isActive = true; avatar.accessibilityLabel = "Публичный аватар"
        nameLabel.font = .preferredFont(forTextStyle: .headline); nameLabel.adjustsFontForContentSizeCategory = true
        changesLabel.font = .preferredFont(forTextStyle: .body); changesLabel.adjustsFontForContentSizeCategory = true; changesLabel.numberOfLines = 0
        reviewButton.setTitle("Просмотреть и обновить", for: .normal); reviewButton.titleLabel?.font = .preferredFont(forTextStyle: .headline); reviewButton.addTarget(self, action: #selector(review), for: .touchUpInside); reviewButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        blockButton.setTitle("Заблокировать", for: .normal); blockButton.setTitleColor(.systemRed, for: .normal); blockButton.addTarget(self, action: #selector(block), for: .touchUpInside); blockButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let text = UIStackView(arrangedSubviews: [nameLabel, changesLabel]); text.axis = .vertical; text.spacing = 4
        let header = UIStackView(arrangedSubviews: [avatar, text]); header.spacing = 12; header.alignment = .center
        let actions = UIStackView(arrangedSubviews: [reviewButton, blockButton]); actions.spacing = 8; actions.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [header, actions]); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)])
    }

    func didReceive(_ notification: UNNotification) {
        nameLabel.text = notification.request.content.title.isEmpty ? "Обновление визитки" : notification.request.content.title
        if let fields = notification.request.content.userInfo["changed_fields"] as? [String], !fields.isEmpty { changesLabel.text = "Изменены: \(fields.joined(separator: ", "))" }
        else { changesLabel.text = notification.request.content.body }
    }

    @objc private func review() { extensionContext?.performNotificationDefaultAction() }

    @objc private func block() {
        if awaitingBlockConfirmation {
            blockButton.setTitle("Заблокировано", for: .normal); blockButton.isEnabled = false; reviewButton.isHidden = true; changesLabel.text = "Будущие обновления скрыты. Системные Контакты не изменены."
            extensionContext?.dismissNotificationContentExtension()
        } else {
            awaitingBlockConfirmation = true; blockButton.setTitle("Подтвердить блокировку", for: .normal); changesLabel.text = "Карточка и будущие обновления будут скрыты. Системные Контакты не изменятся."
        }
    }
}
