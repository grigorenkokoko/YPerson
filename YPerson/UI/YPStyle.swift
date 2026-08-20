import UIKit

enum YPStyle {
    static let canvas = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: 0x0E1218) : UIColor(hex: 0xF6F5F0) }
    static let surface = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: 0x171D27) : .white }
    static let ink = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: 0xF4F6FA) : UIColor(hex: 0x142033) }
    static let indigo = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: 0x94A0FF) : UIColor(hex: 0x4F5FE7) }
    static let mint = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: 0x72DDB5) : UIColor(hex: 0xAEEBD3) }
    static let destructive = UIColor(hex: 0xC9362B)

    static func label(_ text: String, style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = ink
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    static func button(_ title: String, symbol: String? = nil, primary: Bool = false) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 10
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = primary ? indigo : surface
        configuration.baseForegroundColor = primary ? .white : indigo
        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        return button
    }

    static func stack(spacing: CGFloat = 12) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }
}

struct CardTemplatePalette {
    let surface: UIColor
    let accent: UIColor
    let text: UIColor
}

extension CardTemplateDefinition {
    var palette: CardTemplatePalette {
        switch id {
        case CardTemplateCatalog.standardContrast.id:
            return .init(surface: UIColor(hex: 0x142033), accent: UIColor(hex: 0xAEEBD3), text: .white)
        case CardTemplateCatalog.mintConference.id:
            return .init(surface: UIColor(hex: 0xE6F8F0), accent: UIColor(hex: 0x146B4A), text: UIColor(hex: 0x142033))
        case CardTemplateCatalog.indigoStudio.id:
            return .init(surface: UIColor(hex: 0x4F5FE7), accent: UIColor(hex: 0xAEEBD3), text: .white)
        default:
            return .init(surface: YPStyle.surface, accent: YPStyle.indigo, text: YPStyle.ink)
        }
    }
}

extension UIColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

class YPBaseViewController: UIViewController {
    let contentStack = YPStyle.stack(spacing: 16)
    private let scrollView = UIScrollView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = YPStyle.canvas
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32)
        ])
    }

    func sectionTitle(_ text: String) { contentStack.addArrangedSubview(YPStyle.label(text, style: .title2, weight: .bold)) }

    func showMessage(_ title: String, _ message: String, settingsAction: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let settingsAction { alert.addAction(UIAlertAction(title: "Открыть Настройки", style: .default) { _ in settingsAction() }) }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    func explainPermission(title: String, message: String, continueAction: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Продолжить", style: .default) { _ in continueAction() })
        alert.addAction(UIAlertAction(title: "Не сейчас", style: .cancel))
        present(alert, animated: true)
    }
}

final class CardSummaryView: UIView {
    let card: PersonCard
    private let stack = YPStyle.stack(spacing: 6)

    init(card: PersonCard, showPrivate: Bool = false) {
        self.card = card
        super.init(frame: .zero)
        let palette = CardTemplateCatalog.resolve(card.templateID).palette
        backgroundColor = palette.surface
        layer.cornerRadius = 24
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor)
        ])
        let avatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
        avatar.tintColor = palette.accent
        avatar.contentMode = .scaleAspectFit
        avatar.heightAnchor.constraint(equalToConstant: 72).isActive = true
        avatar.accessibilityLabel = "Фото \(card.name)"
        stack.addArrangedSubview(avatar)
        let name = YPStyle.label(card.name, style: .title2, weight: .bold)
        let role = YPStyle.label("\(card.role) · \(card.company)", style: .headline)
        let email = YPStyle.label(card.email)
        let phone = YPStyle.label(showPrivate ? card.phone : "Закрытые поля · Face ID", style: .footnote, weight: .semibold)
        [name, role, email, phone].forEach { label in
            label.textColor = palette.text
            stack.addArrangedSubview(label)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Визитка. \(card.name), \(card.role), \(card.company). \(showPrivate ? card.phone : "Закрытые поля заблокированы")"
        accessibilityTraits = .summaryElement
        stack.isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
