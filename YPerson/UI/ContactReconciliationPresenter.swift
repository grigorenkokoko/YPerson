import ContactsUI
import SwiftUI
import UIKit

final class ContactReconciliationPresenter: NSObject, CNContactViewControllerDelegate {
    private weak var host: YPBaseViewController?
    private let permissions: PermissionCenter
    private let analytics: AppMetricaAnalyticsClient
    private let commitBarrier: ContactReconciliationCommitBarrier
    private var activeSession: ContactReconciliationCommitBarrier.Session?
    private weak var ownedAlert: UIAlertController?
    private var accessManagerController: UIViewController?
    private var accessManagerCompleted = false
    private weak var systemContactController: CNContactViewController?
    private var systemContactSession: ContactReconciliationCommitBarrier.Session?
    private var profileLifecycle = ContactReconciliationProfileLifecycle()

    init(
        host: YPBaseViewController,
        permissions: PermissionCenter,
        analytics: AppMetricaAnalyticsClient,
        commitBarrier: ContactReconciliationCommitBarrier
    ) {
        self.host = host
        self.permissions = permissions
        self.analytics = analytics
        self.commitBarrier = commitBarrier
        super.init()
    }

    func start(for card: PersonCard) {
        guard profileLifecycle.isActive else { return }
        if let activeSession { commitBarrier.invalidateSession(activeSession) }
        guard let session = commitBarrier.beginSession() else { return }
        activeSession = session
        dismissOwnedUI()
        guard isCurrent(session), let host else { return }
        host.explainPermission(
            title: "Синхронизация с Контактами",
            message: "Контакты нужны, чтобы находить дубликаты, добавлять визитки YPerson в адресную книгу и обновлять их при изменениях владельца."
        ) { [weak self] in
            guard let self, self.isCurrent(session) else { return }
            self.continueAfterPermission(for: card, session: session)
        }
    }

    func beginProfileDeletion() {
        profileLifecycle.beginDeletion()
        if let activeSession { commitBarrier.invalidateSession(activeSession) }
        activeSession = nil
        dismissOwnedUI()
    }

    func applyProfileReactivation() {
        profileLifecycle.reactivateForUserCreation()
    }

    private func dismissOwnedUI() {
        accessManagerCompleted = true
        ownedAlert?.dismiss(animated: false)
        ownedAlert = nil
        accessManagerController?.dismiss(animated: false)
        accessManagerController = nil
        dismissSystemContactController()
    }

    private func continueAfterPermission(
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        switch permissions.contactsState() {
        case .authorized:
            loadPlan(for: card, scope: .complete, session: session)
        case .limited:
            loadPlan(for: card, scope: .limited, session: session)
        case .notDetermined:
            permissions.requestContacts { [weak self] state in
                guard let self, self.isCurrent(session) else { return }
                self.handleRequestedState(state, for: card, session: session)
            }
        case .denied, .restricted, .unavailable:
            offerReadUnavailableFallback(for: card, session: session)
        }
    }

    private func handleRequestedState(
        _ state: AuthorizationState,
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        switch state {
        case .authorized:
            loadPlan(for: card, scope: .complete, session: session)
        case .limited:
            loadPlan(for: card, scope: .limited, session: session)
        default:
            offerReadUnavailableFallback(for: card, session: session)
        }
    }

    private func loadPlan(
        for card: PersonCard,
        scope: ContactReconciliationScope,
        choosing candidateIdentifier: String? = nil,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        permissions.reconciliation(for: card, scope: scope, choosing: candidateIdentifier) { [weak self] result in
            guard let self, self.isCurrent(session) else { return }
            switch result {
            case .success(.plan(let plan)):
                self.present(plan, for: card, session: session)
            case .success(.chooseCandidate(let candidates)):
                self.chooseContact(candidates, for: card, scope: scope, session: session)
            case .success(.insufficientAccess):
                self.offerLimitedAccess(for: card, session: session)
            case .failure(let error):
                guard self.isCurrent(session) else { return }
                self.host?.showMessage("Контакты недоступны", error.localizedDescription, settingsAction: { [weak self] in
                    guard let self, self.isCurrent(session) else { return }
                    self.permissions.openSystemSettings()
                })
            }
        }
    }

    private func chooseContact(
        _ candidates: [ContactReconciliationCandidate],
        for card: PersonCard,
        scope: ContactReconciliationScope,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        let alert = UIAlertController(
            title: "Выберите контакт",
            message: "Найдено несколько совпадений для «\(card.name)». Номер, компания и маскированные поля помогают различить карточки. До выбора и подтверждения ничего не изменится.",
            preferredStyle: .actionSheet
        )
        for (index, candidate) in candidates.enumerated() {
            let details = candidate.identityDetail.isEmpty ? "Без дополнительных данных" : candidate.identityDetail
            alert.addAction(UIAlertAction(title: "\(index + 1). \(candidate.name) · \(details)", style: .default) { [weak self] _ in
                guard let self, self.isCurrent(session) else { return }
                self.loadPlan(for: card, scope: scope, choosing: candidate.identifier, session: session)
            })
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        presentOwned(alert, session: session)
    }

    private func present(
        _ plan: ContactReconciliationPlan,
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session), let host else { return }
        let changedFields = plan.changedFields.isEmpty
            ? "Изменений нет."
            : "Изменятся: \(plan.changedFields.joined(separator: ", "))."
        let identity = plan.candidate.map { candidate in
            let detail = candidate.identityDetail.isEmpty ? "без дополнительных данных" : candidate.identityDetail
            return "Контакт: \(candidate.name) · \(detail)."
        }

        switch plan.action {
        case .noChange:
            guard isCurrent(session) else { return }
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
                guard let self, self.isCurrent(session) else { return }
                self.apply(plan, for: card, session: session)
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            presentOwned(alert, session: session)
        }
    }

    private func apply(
        _ plan: ContactReconciliationPlan,
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        permissions.apply(
            plan,
            for: card,
            session: session,
            commitBarrier: commitBarrier
        ) { [weak self] result in
            guard let self, self.isCurrent(session), let host = self.host else { return }
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
                self.offerPlanRefresh(for: card, message: error.localizedDescription, session: session)
            case .failure(let error):
                host.showMessage("Не удалось сохранить", error.localizedDescription)
            }
        }
    }

    private func offerPlanRefresh(
        for card: PersonCard,
        message: String,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        let alert = UIAlertController(title: "План изменился", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Показать новый план", style: .default) { [weak self] _ in
            guard let self, self.isCurrent(session) else { return }
            self.continueAfterPermission(for: card, session: session)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        presentOwned(alert, session: session)
    }

    private func offerLimitedAccess(
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        let alert = UIAlertController(
            title: "Доступ к Контактам ограничен",
            message: "YPerson видит только выбранные вами контакты и не может считать отсутствие совпадения окончательным или безопасно добавить новую карточку. Измените доступ через системный менеджер либо проверьте и сохраните карточку в форме Apple.",
            preferredStyle: .alert
        )
        if #available(iOS 18.0, *) {
            alert.addAction(UIAlertAction(title: "Изменить доступ", style: .default) { [weak self] _ in
                guard let self, self.isCurrent(session) else { return }
                self.presentLimitedAccessManager(for: card, session: session)
            })
        }
        alert.addAction(UIAlertAction(title: "Открыть форму Apple", style: .default) { [weak self] _ in
            guard let self, self.isCurrent(session) else { return }
            self.presentSystemContactForm(for: card, session: session)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        presentOwned(alert, session: session)
    }

    private func offerReadUnavailableFallback(
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session) else { return }
        let alert = UIAlertController(
            title: "Чтение Контактов недоступно",
            message: "YPerson не может проверить дубликаты. Можно открыть системную форму Apple и самостоятельно проверить карточку перед сохранением.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Открыть форму Apple", style: .default) { [weak self] _ in
            guard let self, self.isCurrent(session) else { return }
            self.presentSystemContactForm(for: card, session: session)
        })
        alert.addAction(UIAlertAction(title: "Открыть Настройки", style: .default) { [weak self] _ in
            guard let self, self.isCurrent(session) else { return }
            self.permissions.openSystemSettings()
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        presentOwned(alert, session: session)
    }

    private func presentSystemContactForm(
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session), let host else { return }
        let controller = CNContactViewController(forNewContact: permissions.makeContact(card))
        controller.delegate = self
        systemContactController = controller
        systemContactSession = session
        guard isCurrent(session) else {
            systemContactController = nil
            systemContactSession = nil
            return
        }
        if let navigationController = host.navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            host.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }

    func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        let session = systemContactSession
        dismissSystemContactController()
        guard let session, isCurrent(session) else { return }
    }

    @available(iOS 18.0, *)
    private func presentLimitedAccessManager(
        for card: PersonCard,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session), let host else { return }
        accessManagerCompleted = false
        let view = ContactAccessManagerView { [weak self] _ in
            guard let self, self.isCurrent(session), !self.accessManagerCompleted else { return }
            self.accessManagerCompleted = true
            self.accessManagerController?.dismiss(animated: true) { [weak self] in
                guard let self, self.isCurrent(session) else { return }
                self.accessManagerController = nil
                self.continueAfterPermission(for: card, session: session)
            }
        }
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        accessManagerController = controller
        guard isCurrent(session) else { return }
        host.present(controller, animated: false)
    }

    private func presentOwned(
        _ alert: UIAlertController,
        session: ContactReconciliationCommitBarrier.Session
    ) {
        guard isCurrent(session), let host else { return }
        ownedAlert?.dismiss(animated: false)
        ownedAlert = alert
        guard isCurrent(session) else { return }
        host.present(alert, animated: true)
    }

    private func dismissSystemContactController() {
        guard let controller = systemContactController else {
            systemContactSession = nil
            return
        }
        if let navigationController = controller.navigationController {
            if navigationController.viewControllers.first === controller,
               navigationController.presentingViewController != nil {
                navigationController.dismiss(animated: false)
            } else if navigationController.topViewController === controller {
                navigationController.popViewController(animated: false)
            }
        } else {
            controller.dismiss(animated: false)
        }
        systemContactController = nil
        systemContactSession = nil
    }

    private func isCurrent(_ session: ContactReconciliationCommitBarrier.Session) -> Bool {
        activeSession == session && commitBarrier.isCurrent(session)
    }

    deinit {
        if let activeSession { commitBarrier.invalidateSession(activeSession) }
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
