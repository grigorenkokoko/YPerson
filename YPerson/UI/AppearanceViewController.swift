import UIKit

final class AppearanceViewController: YPBaseViewController {
    private var previewCard: PersonCard
    private var selectedTemplateID: String
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private let onSelect: (String) -> Void
    private let previewStack = YPStyle.stack(spacing: 0)
    private var templateButtons: [String: UIButton] = [:]

    init(
        card: PersonCard,
        selectedTemplateID: String,
        permissions: PermissionCenter,
        analytics: AppMetricaAnalyticsClient,
        onSelect: @escaping (String) -> Void
    ) {
        self.previewCard = card
        self.selectedTemplateID = CardTemplateCatalog.resolve(selectedTemplateID).id
        self.previewCard.templateID = self.selectedTemplateID
        self.permissions = permissions
        self.analytics = analytics
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Оформление"; navigationItem.largeTitleDisplayMode = .never
        sectionTitle("Предпросмотр")
        contentStack.addArrangedSubview(previewStack)
        sectionTitle("Обычные шаблоны")
        addTemplate(CardTemplateCatalog.standardClean)
        addTemplate(CardTemplateCatalog.standardContrast)
        sectionTitle("Спонсорские · бесплатно")
        contentStack.addArrangedSubview(YPStyle.label("Шаблоны доступны независимо от решения об отслеживании.", style: .footnote))
        addTemplate(CardTemplateCatalog.mintConference)
        addTemplate(CardTemplateCatalog.indigoStudio)
        let tracking = YPStyle.button("Помочь оценивать рекламу", symbol: "chart.bar.doc.horizontal"); tracking.addTarget(self, action: #selector(requestTracking), for: .touchUpInside); contentStack.addArrangedSubview(tracking)
        renderPreview()
        renderSelection()
    }

    private func addTemplate(_ template: CardTemplateDefinition) {
        let button = YPStyle.button(template.title, symbol: template.sponsoredCategory == nil ? "rectangle.3.group" : "sparkles")
        button.accessibilityHint = template.sponsoredCategory == nil ? "Обычный шаблон" : "Бесплатный спонсорский шаблон"
        button.addAction(UIAction { [weak self] _ in self?.select(template) }, for: .touchUpInside)
        templateButtons[template.id] = button
        contentStack.addArrangedSubview(button)
    }

    private func select(_ template: CardTemplateDefinition) {
        selectedTemplateID = template.id
        previewCard.templateID = template.id
        onSelect(template.id)
        if let category = template.sponsoredCategory {
            analytics.report(.sponsoredTemplateSelected(category))
        }
        renderPreview()
        renderSelection()
        UIAccessibility.post(notification: .announcement, argument: "Выбран шаблон \(template.title)")
    }

    private func renderPreview() {
        previewStack.arrangedSubviews.forEach {
            previewStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        previewStack.addArrangedSubview(CardSummaryView(card: previewCard))
    }

    private func renderSelection() {
        for (templateID, button) in templateButtons {
            let isSelected = templateID == selectedTemplateID
            let template = CardTemplateCatalog.resolve(templateID)
            button.configuration?.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : template.sponsoredCategory == nil ? "rectangle.3.group" : "sparkles")
            button.configuration?.subtitle = isSelected ? "Выбрано" : nil
            if isSelected {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }
    }

    @objc private func requestTracking() {
        explainPermission(title: "Оценка рекламных кампаний", message: "Разрешите отслеживание, чтобы YPerson мог оценивать рекламные кампании и поддерживать бесплатные спонсорские шаблоны. Отказ не меняет доступность шаблонов.") { [weak self] in
            self?.permissions.requestTracking { authorized, state in
                self?.analytics.setTrackingAuthorized(authorized)
                self?.showMessage(authorized ? "Измерение включено" : "Отслеживание выключено", authorized ? "AppMetrica может использовать IDFA только для рекламной атрибуции." : "IDFA и межсервисное отслеживание не используются. Все шаблоны доступны.")
            }
        }
    }
}
