import ContactsUI
import SwiftUI
import UIKit

final class ContactReconciliationPresenter {
    private weak var host: YPBaseViewController?
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private var accessManagerController: UIViewController?
    private var accessManagerCompleted = false

    init(host: YPBaseViewController, permissions: PermissionCenter, analytics: AppMetricaAnalyticsClient) {
        self.host = host
        self.permissions = permissions
        self.analytics = analytics
    }

    func start(for card: PersonCard) {
        guard let host else { return }
        host.explainPermission(
            title: "Синхронизация с Контактами",
            message: "Контакты нужны, чтобы находить дубликаты, добавлять визитки YPerson в адресную книгу и обновлять их при изменениях владельца."
        ) { [weak self] in
            self?.continueAfterPermission(for: card)
        }
    }

    private func continueAfterPermission(for card: PersonCard) {
        switch permissions.contactsState() {
        case .authorized:
            loadPlan(for: card, scope: .complete)
        case .limited:
            loadPlan(for: card, scope: .limited)
        case .notDetermined:
            permissions.requestContacts { [weak self] state in
                self?.handleRequestedState(state, for: card)
            }
        case .denied, .restricted, .unavailable:
            offerReadUnavailableFallback(for: card)
        }
    }

    private func handleRequestedState(_ state: AuthorizationState, for card: PersonCard) {
        switch state {
        case .authorized:
            loadPlan(for: card, scope: .complete)
        case .limited:
            loadPlan(for: card, scope: .limited)
        default:
            offerReadUnavailableFallback(for: card)
        }
    }

    private func loadPlan(
        for card: PersonCard,
        scope: ContactReconciliationScope,
        choosing candidateIdentifier: String? = nil
    ) {
        permissions.reconciliation(for: card, scope: scope, choosing: candidateIdentifier) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.plan(let plan)):
                self.present(plan, for: card)
            case .success(.chooseCandidate(let candidates)):
                self.chooseContact(candidates, for: card, scope: scope)
            case .success(.insufficientAccess):
                self.offerLimitedAccess(for: card)
            case .failure(let error):
                self.host?.showMessage("Контакты недоступны", error.localizedDescription, settingsAction: self.permissions.openSystemSettings)
            }
        }
    }

    private func chooseContact(
        _ candidates: [ContactReconciliationCandidate],
        for card: PersonCard,
        scope: ContactReconciliationScope
    ) {
        guard let host else { return }
        let alert = UIAlertController(
            title: "Выберите контакт",
            message: "Найдено несколько совпадений для «\(card.name)». Номер, компания и маскированные поля помогают различить карточки. До выбора и подтверждения ничего не изменится.",
            preferredStyle: .actionSheet
        )
        for (index, candidate) in candidates.enumerated() {
            let details = candidate.identityDetail.isEmpty ? "Без дополнительных данных" : candidate.identityDetail
            alert.addAction(UIAlertAction(title: "\(index + 1). \(candidate.name) · \(details)", style: .default) { [weak self] _ in
                self?.loadPlan(for: card, scope: scope, choosing: candidate.identifier)
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        host.present(alert, animated: true)
    }

    private func present(_ plan: ContactReconciliationPlan, for card: PersonCard) {
        guard let host else { return }
        let changedFields = plan.changedFields.isEmpty
            ? "Изменений нет."
            : "Изменятся: \(plan.changedFields.joined(separator: ", "))."
        let identity = plan.candidate.map { candidate in
            let detail = candidate.identityDetail.isEmpty ? "без дополнительных данных" : candidate.identityDetail
            return "Контакт: \(candidate.name) · \(detail)."
        }

        switch plan.action {
        case .noChange:
            host.showMessage("Без изменений", "\(identity ?? "Выбранный контакт.") \(changedFields) Контакт уже актуален.")
        case .add, .update:
            let isAdd = plan.action == .add
            let operation = isAdd ? "Добавить" : "Обновить"
            let target = isAdd
                ? "Будет добавлена новая карточка «\(card.name)»."
                : "Будет обновлён выбранный контакт. \(identity ?? "")"
            let alert = UIAlertController(
                title: "План изменений",
                message: "\(target) \(changedFields) Ничего не изменится без подтверждения.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: operation, style: .default) { [weak self] _ in
                self?.apply(plan, for: card)
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            host.present(alert, animated: true)
        }
    }

    private func apply(_ plan: ContactReconciliationPlan, for card: PersonCard) {
        permissions.apply(plan, for: card) { [weak self] result in
            guard let self, let host = self.host else { return }
            switch result {
            case .success(.add):
                self.analytics.report(.contactSaved)
                host.showMessage("Контакт добавлен", "Карточка «\(card.name)» добавлена в Контакты.")
            case .success(.update):
                self.analytics.report(.contactSaved)
                host.showMessage("Контакт обновлён", "Обновлены: \(plan.changedFields.joined(separator: ", ")).")
            case .success(.noChange):
                host.showMessage("Без изменений", "Контакт уже актуален.")
            case .failure(let error as ContactReconciliationPlannerError) where error == .stalePlan || error == .invalidCandidate:
                self.offerPlanRefresh(for: card, message: error.localizedDescription)
            case .failure(let error):
                host.showMessage("Не удалось сохранить", error.localizedDescription)
            }
        }
    }

    private func offerPlanRefresh(for card: PersonCard, message: String) {
        guard let host else { return }
        let alert = UIAlertController(title: "План изменился", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Показать новый план", style: .default) { [weak self] _ in
            self?.continueAfterPermission(for: card)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        host.present(alert, animated: true)
    }

    private func offerLimitedAccess(for card: PersonCard) {
        guard let host else { return }
        let alert = UIAlertController(
            title: "Доступ к Контактам ограничен",
            message: "YPerson видит только выбранные вами контакты и не может считать отсутствие совпадения окончательным или безопасно добавить новую карточку. Измените доступ через системный менеджер либо проверьте и сохраните карточку в форме Apple.",
            preferredStyle: .alert
        )
        if #available(iOS 18.0, *) {
            alert.addAction(UIAlertAction(title: "Изменить доступ", style: .default) { [weak self] _ in
                self?.presentLimitedAccessManager(for: card)
            })
        }
        alert.addAction(UIAlertAction(title: "Открыть форму Apple", style: .default) { [weak self] _ in
            self?.presentSystemContactForm(for: card)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        host.present(alert, animated: true)
    }

    private func offerReadUnavailableFallback(for card: PersonCard) {
        guard let host else { return }
        let alert = UIAlertController(
            title: "Чтение Контактов недоступно",
            message: "YPerson не может проверить дубликаты. Можно открыть системную форму Apple и самостоятельно проверить карточку перед сохранением.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Открыть форму Apple", style: .default) { [weak self] _ in
            self?.presentSystemContactForm(for: card)
        })
        alert.addAction(UIAlertAction(title: "Открыть Настройки", style: .default) { [weak self] _ in
            self?.permissions.openSystemSettings()
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        host.present(alert, animated: true)
    }

    private func presentSystemContactForm(for card: PersonCard) {
        guard let host else { return }
        let controller = CNContactViewController(forNewContact: permissions.makeContact(card))
        if let navigationController = host.navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            host.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }

    @available(iOS 18.0, *)
    private func presentLimitedAccessManager(for card: PersonCard) {
        guard let host else { return }
        accessManagerCompleted = false
        let view = ContactAccessManagerView { [weak self] _ in
            guard let self, !self.accessManagerCompleted else { return }
            self.accessManagerCompleted = true
            self.accessManagerController?.dismiss(animated: true) { [weak self] in
                self?.accessManagerController = nil
                self?.continueAfterPermission(for: card)
            }
        }
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        accessManagerController = controller
        host.present(controller, animated: false)
    }
}

@available(iOS 18.0, *)
private struct ContactAccessManagerView: View {
    @State private var isPresented = false
    let completion: ([String]) -> Void

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .contactAccessPicker(isPresented: $isPresented, completionHandler: completion)
            .onAppear { isPresented = true }
            .onChange(of: isPresented) { presented in
                if !presented { completion([]) }
            }
    }
}
