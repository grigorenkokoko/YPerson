import UIKit

final class ShortCodeViewController: YPBaseViewController {
    private let code: String
    private let expiresAt: Date
    private let onClose: () -> Void
    private var didClose = false

    init(code: String, expiresAt: Date, onClose: @escaping () -> Void) {
        guard let canonicalCode = ManualExchangeCode.normalize(code) else {
            preconditionFailure("ShortCodeViewController requires a valid exchange code")
        }
        self.code = canonicalCode
        self.expiresAt = expiresAt
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Короткий код"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Закрыть",
            style: .plain,
            target: self,
            action: #selector(close)
        )

        let codeLabel = YPStyle.label(code, style: .largeTitle, weight: .bold)
        codeLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .monospacedSystemFont(ofSize: 32, weight: .bold)
        )
        codeLabel.textAlignment = .center
        codeLabel.accessibilityLabel = "Короткий код обмена: \(code)"
        contentStack.addArrangedSubview(codeLabel)

        let expiry = Self.expiryFormatter.string(from: expiresAt)
        let expiryLabel = YPStyle.label(
            "Код действует до \(expiry) и сработает один раз.",
            style: .body
        )
        expiryLabel.textAlignment = .center
        contentStack.addArrangedSubview(expiryLabel)

        let copyButton = YPStyle.button("Скопировать код", symbol: "doc.on.doc", primary: true)
        copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        contentStack.addArrangedSubview(copyButton)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let wasRemoved = isMovingFromParent
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
        guard wasRemoved, !didClose else { return }
        didClose = true
        onClose()
    }

    @objc private func copyCode() {
        UIPasteboard.general.string = code
        UIAccessibility.post(notification: .announcement, argument: "Код скопирован")
    }

    @objc private func close() {
        if let navigationController,
           navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
