import Foundation
import UIKit
import UserNotifications

@MainActor
final class YPersonExperienceBuilder {
    private let configuration: AppConfiguration
    private let session: URLSession
    private let snapshotStore: AppGroupSnapshotStore?
    private let syncCoordinator: SyncCoordinator
    private let analytics: AppMetricaAnalyticsClient
    private let permissions: PermissionCenter
    private let credentialStore: InstallationCredentialStore
    private let mediaTransfer: MediaTransferClient
    private let nearby = NearbyExchangeController()
    private let photoScanner = PhotoCardScanner()
    private let audio = AudioGreetingController()
    private let imageSaver = CardImageSaver()
    private weak var output: (any YPersonExperienceOutput)?
    private weak var rootViewController: MainTabBarController?
    private weak var peopleViewController: PeopleViewController?
    private var pendingPublicReplies: [PublicContactReply] = []
    private var suppressedPublicReplyIDs: Set<String> = []
    private var defersPublicReplyReviewUntilForeground = false

    init(configuration: AppConfiguration) throws {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 12
        sessionConfiguration.timeoutIntervalForResource = 20
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
        let store = AppGroupSnapshotStore(appGroupIdentifier: configuration.appGroupIdentifier)
        self.snapshotStore = store
        let credentialStore = InstallationCredentialStore(service: "\(configuration.appGroupIdentifier).installation")
        self.credentialStore = credentialStore
        let mediaTransfer = MediaTransferClient(session: session)
        self.mediaTransfer = mediaTransfer
        self.syncCoordinator = try SyncCoordinator(
            baseURL: configuration.apiBaseURL,
            session: session,
            snapshotStore: store,
            credentialStore: credentialStore,
            mediaTransfer: mediaTransfer
        )
        self.analytics = AppMetricaAnalyticsClient(apiKey: configuration.appMetricaAPIKey, initialConsent: store?.analyticsConsent ?? false)
        self.permissions = PermissionCenter(notificationCenter: UNUserNotificationCenter.current())
        self.analytics.setRemoteKillSwitch(store?.cachedConfiguration()?.0.analyticsKillSwitch ?? false)
    }

    func makeRootViewController(
        context: YPersonExperienceContext,
        output: any YPersonExperienceOutput
    ) -> UIViewController {
        self.output = output
        _ = analytics.activateIfConsented()
        var ownCard = snapshotStore?.readOwnCard()
        var savedPeople = snapshotStore?.readPeople() ?? []
        var usesReviewFixtures = false
#if DEBUG
        if ProcessInfo.processInfo.environment["YP_SCREENSHOT_STATE"] != nil {
            ownCard = .reviewOwn
            savedPeople = [.reviewAlexey, .reviewMaria]
            usesReviewFixtures = true
        }
#endif
        let makeAppearance = { [permissions, analytics]
            (card: PersonCard, selectedTemplateID: String, onSelect: @escaping (String) -> Void) in
            AppearanceViewController(
                card: card,
                selectedTemplateID: selectedTemplateID,
                permissions: permissions,
                analytics: analytics,
                onSelect: onSelect
            )
        }
        let makeEditor: (PersonCard?, @escaping (PersonCard) throws -> Void) -> UIViewController = { [permissions, audio] card, onSave in
            CardEditorViewController(card: card, permissions: permissions, audio: audio, makeAppearance: makeAppearance, onSave: onSave)
        }
        let card = CardViewController(card: ownCard, persistsChanges: !usesReviewFixtures, permissions: permissions, audio: audio, imageSaver: imageSaver, syncCoordinator: syncCoordinator, analytics: analytics, snapshotStore: snapshotStore, makeEditor: makeEditor)
        let person = { [permissions, imageSaver, syncCoordinator, analytics, snapshotStore, mediaTransfer, audio] card in
            PersonViewController(card: card, permissions: permissions, imageSaver: imageSaver, syncCoordinator: syncCoordinator, mediaTransfer: mediaTransfer, audio: audio, analytics: analytics, snapshotStore: snapshotStore)
        }
        let people = PeopleViewController(
            people: savedPeople,
            permissions: permissions,
            analytics: analytics,
            makePerson: person,
            onContactsImported: { [snapshotStore] cards in
                guard let snapshotStore else {
                    throw NSError(
                        domain: "YPerson.ContactsImport",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Локальное хранилище недоступно"]
                    )
                }
                try snapshotStore.replacePeople(cards)
                return snapshotStore.readPeople()
            }
        )
        let exchange = ExchangeViewController(
            nearby: nearby,
            photoScanner: photoScanner,
            permissions: permissions,
            audio: audio,
            syncCoordinator: syncCoordinator,
            analytics: analytics,
            snapshotStore: snapshotStore,
            ownCard: { [weak card] in card?.currentCard },
            onPersonSaved: { [weak people, snapshotStore] _ in
                people?.reload(people: snapshotStore?.readPeople() ?? [])
            }
        )
        let privacy = PrivacyViewController(permissions: permissions, audio: audio, analytics: analytics, snapshotStore: snapshotStore, syncCoordinator: syncCoordinator, configuration: configuration)
        let root = MainTabBarController(card: card, exchange: exchange, people: people, privacy: privacy)
        self.rootViewController = root
        self.peopleViewController = people
        root.route(to: context.entryPoint)
        if !usesReviewFixtures {
            syncCoordinator.onPeopleChanged = { [weak people, snapshotStore] in
                people?.reload(people: snapshotStore?.readPeople() ?? [])
            }
            syncCoordinator.onOwnCardChanged = { [weak card] published in card?.applyPublishedCard(published) }
            syncCoordinator.onProfileDeleted = { [weak card, weak people, mediaTransfer] in
                mediaTransfer.removeAllCachedAudio()
                card?.applyProfileDeletion()
                people?.reload(people: [])
            }
            syncCoordinator.onAudioInvalidated = { [mediaTransfer] in
                mediaTransfer.removeAllCachedAudio()
            }
            syncCoordinator.onPublicRepliesChanged = { [weak self] replies in
                self?.receivePublicReplies(replies)
            }
            refreshPeople()
        }
#if DEBUG
        applyVerificationState(to: root, card: card, exchange: exchange, privacy: privacy, makePerson: person, makeEditor: makeEditor, makeAppearance: makeAppearance)
#endif
        return root
    }

    func route(to entryPoint: YPersonEntryPoint) {
        rootViewController?.route(to: entryPoint)
    }

    func handle(_ event: YPersonLifecycleEvent) {
        switch event {
        case .didEnterForeground:
            defersPublicReplyReviewUntilForeground = false
            presentNextPublicReplyIfPossible()
            refreshPeople()
        case .pushTokenChanged(let token):
            updatePushToken(token)
        }
    }

#if DEBUG
    private func applyVerificationState(to root: MainTabBarController, card: CardViewController, exchange: ExchangeViewController, privacy: PrivacyViewController, makePerson: @escaping (PersonCard) -> UIViewController, makeEditor: @escaping (PersonCard?, @escaping (PersonCard) throws -> Void) -> UIViewController, makeAppearance: @escaping (PersonCard, String, @escaping (String) -> Void) -> UIViewController) {
        switch ProcessInfo.processInfo.environment["YP_SCREENSHOT_STATE"] {
        case "S2": root.selectedIndex = 1
        case "S3": root.selectedIndex = 2
        case "S4":
            root.selectedIndex = 2
            DispatchQueue.main.async {
                (root.selectedViewController as? UINavigationController)?.pushViewController(makePerson(.reviewAlexey), animated: false)
            }
        case "S5":
            root.selectedIndex = 0
            DispatchQueue.main.async {
                (root.selectedViewController as? UINavigationController)?.pushViewController(makeEditor(.reviewOwn, { _ in }), animated: false)
            }
        case "S6":
            root.selectedIndex = 0
            DispatchQueue.main.async {
                let navigation = root.selectedViewController as? UINavigationController
                let editor = makeEditor(.reviewOwn, { _ in })
                editor.loadViewIfNeeded()
                navigation?.pushViewController(editor, animated: false)
                DispatchQueue.main.async {
                    navigation?.pushViewController(makeAppearance(.reviewOwn, PersonCard.reviewOwn.templateID, { _ in }), animated: false)
                }
            }
        case "S7": root.selectedIndex = 3
        case "S7_DELETE":
            root.selectedIndex = 3
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak privacy] in privacy?.showDeletionConfirmation() }
        case "REVIEW_QR":
            root.selectedIndex = 0
            DispatchQueue.main.async { [weak card] in card?.showVerificationQR() }
        case "S8":
            root.selectedIndex = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak exchange] in exchange?.showVerificationImport() }
        default: break
        }
    }
#endif

    private func updatePushToken(_ token: String?) {
        Task { [syncCoordinator] in await syncCoordinator.updatePushToken(token) }
    }

    private func refreshPeople() {
        Task { [syncCoordinator] in await syncCoordinator.bootstrap() }
    }

    private func receivePublicReplies(_ replies: [PublicContactReply]) {
        pendingPublicReplies = replies.filter { !suppressedPublicReplyIDs.contains($0.id) }
        guard !defersPublicReplyReviewUntilForeground else { return }
        presentNextPublicReplyIfPossible()
    }

    private func presentNextPublicReplyIfPossible() {
        guard let rootViewController,
              rootViewController.viewIfLoaded?.window != nil,
              !hasPresentedController(in: rootViewController),
              let reply = pendingPublicReplies.first else {
            return
        }
        let review = PublicReplyReviewViewController(
            reply: reply,
            onAccept: { [weak self] card in
                self?.acceptPublicReply(card, replyID: reply.id)
            },
            onLater: { [weak self] in
                self?.deferCurrentPublicReply()
            }
        )
        rootViewController.present(review, animated: true)
    }

    private func acceptPublicReply(_ card: PersonCard, replyID: String) {
        guard !suppressedPublicReplyIDs.contains(replyID) else { return }
        do {
            guard let snapshotStore else {
                throw PublicReplySaveError.localStorageUnavailable
            }
            try snapshotStore.upsertPerson(card)
        } catch {
            currentPublicReplyReview?.showSaveFailure()
            return
        }

        peopleViewController?.reload(people: snapshotStore?.readPeople() ?? [])
        suppressedPublicReplyIDs.insert(replyID)
        pendingPublicReplies.removeAll { $0.id == replyID }
        defersPublicReplyReviewUntilForeground = true
        Task { [syncCoordinator] in
            try? await syncCoordinator.dismissPublicReply(id: replyID)
        }
        currentPublicReplyReview?.dismiss(animated: true)
    }

    private func deferCurrentPublicReply() {
        defersPublicReplyReviewUntilForeground = true
        currentPublicReplyReview?.dismiss(animated: true)
    }

    private var currentPublicReplyReview: PublicReplyReviewViewController? {
        rootViewController?.presentedViewController as? PublicReplyReviewViewController
    }

    private func hasPresentedController(in controller: UIViewController) -> Bool {
        if controller.presentedViewController != nil { return true }
        if let tab = controller as? UITabBarController,
           let selected = tab.selectedViewController {
            return hasPresentedController(in: selected)
        }
        if let navigation = controller as? UINavigationController,
           let visible = navigation.visibleViewController {
            return hasPresentedController(in: visible)
        }
        return false
    }
}

private enum PublicReplySaveError: Error {
    case localStorageUnavailable
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
