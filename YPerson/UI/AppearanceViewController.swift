import UIKit

final class AppearanceViewController: YPBaseViewController {
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient

    init(permissions: PermissionCenter, analytics: AppMetricaAnalyticsClient) { self.permissions = permissions; self.analytics = analytics; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Оформление"; navigationItem.largeTitleDisplayMode = .never
        sectionTitle("Обычные шаблоны")
        addTemplate("Чистый", category: "standard_clean", sponsored: false); addTemplate("Контрастный", category: "standard_contrast", sponsored: false)
        sectionTitle("Спонсорские · бесплатно")
        contentStack.addArrangedSubview(YPStyle.label("Шаблоны доступны независимо от решения об отслеживании.", style: .footnote))
        addTemplate("Mint Conference", category: "sponsored_event", sponsored: true); addTemplate("Indigo Studio", category: "sponsored_studio", sponsored: true)
        let tracking = YPStyle.button("Помочь оценивать рекламу", symbol: "chart.bar.doc.horizontal"); tracking.addTarget(self, action: #selector(requestTracking), for: .touchUpInside); contentStack.addArrangedSubview(tracking)
    }

    private func addTemplate(_ title: String, category: String, sponsored: Bool) {
        let button = YPStyle.button(title, symbol: sponsored ? "sparkles" : "rectangle.3.group"); button.accessibilityHint = sponsored ? "Бесплатный спонсорский шаблон" : "Обычный шаблон"; button.addAction(UIAction { [weak self] _ in self?.analytics.report(sponsored ? .sponsoredTemplateSelected(category) : .cardCreated); self?.showMessage("Шаблон выбран", "\(title) применён к карточке.") }, for: .touchUpInside); contentStack.addArrangedSubview(button)
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
