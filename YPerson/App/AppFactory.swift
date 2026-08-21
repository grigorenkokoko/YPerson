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
    private let credentialStore: any InstallationCredentialStoring
    private let mediaTransfer: MediaTransferClient
    private let persistsUserChanges: Bool
    private let nearby = NearbyExchangeController()
    private let photoScanner = PhotoCardScanner()
    private let audio = AudioGreetingController()
    private let imageSaver = CardImageSaver()
    private weak var output: (any YPersonExperienceOutput)?
    private weak var rootViewController: MainTabBarController?
    private let personControllers = NSHashTable<PersonViewController>.weakObjects()
    private var bootstrapTaskOwnership = ProfileBootstrapTaskOwnership()
    private var bootstrapTasks: [ProfileBootstrapTaskOwnership.Ticket: Task<Void, Never>] = [:]
    private var pushTokenTask: Task<Void, Never>?

    init(configuration: AppConfiguration) throws {
        self.configuration = configuration
#if DEBUG
        let usesReviewFixtures = ReviewFixtureIsolationPolicy.isEnabled()
        self.persistsUserChanges = !usesReviewFixtures
#else
        self.persistsUserChanges = true
#endif
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 12
        sessionConfiguration.timeoutIntervalForResource = 20
        sessionConfiguration.waitsForConnectivity = true
#if DEBUG
        if usesReviewFixtures {
            ReviewFixtureIsolationPolicy.isolate(sessionConfiguration)
        }
#endif
        self.session = URLSession(configuration: sessionConfiguration)
        let store: AppGroupSnapshotStore?
#if DEBUG
        if usesReviewFixtures {
            store = AppGroupSnapshotStore.inMemory()
        } else {
            store = AppGroupSnapshotStore(appGroupIdentifier: configuration.appGroupIdentifier)
        }
#else
        store = AppGroupSnapshotStore(appGroupIdentifier: configuration.appGroupIdentifier)
#endif
        self.snapshotStore = store
        let credentialStore: any InstallationCredentialStoring
#if DEBUG
        if usesReviewFixtures {
            credentialStore = EphemeralInstallationCredentialStore(
                seed: ReviewFixtureIsolationPolicy.credential
            )
        } else {
            credentialStore = InstallationCredentialStore(
                service: "\(configuration.appGroupIdentifier).installation"
            )
        }
#else
        credentialStore = InstallationCredentialStore(
            service: "\(configuration.appGroupIdentifier).installation"
        )
#endif
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
        if !syncCoordinator.isProfileActive {
            ownCard = nil
            savedPeople = []
        }
#if DEBUG
        if !persistsUserChanges {
            ownCard = .reviewOwn
            savedPeople = [.reviewAlexey, .reviewMaria]
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
        let card = CardViewController(card: ownCard, persistsChanges: persistsUserChanges, permissions: permissions, audio: audio, imageSaver: imageSaver, syncCoordinator: syncCoordinator, analytics: analytics, snapshotStore: snapshotStore, makeEditor: makeEditor)
        let person = { [weak self, permissions, imageSaver, syncCoordinator, analytics, snapshotStore, mediaTransfer, audio] card in
            let controller = PersonViewController(card: card, permissions: permissions, imageSaver: imageSaver, syncCoordinator: syncCoordinator, mediaTransfer: mediaTransfer, audio: audio, analytics: analytics, snapshotStore: snapshotStore)
            self?.personControllers.add(controller)
            return controller
        }
        let people = PeopleViewController(
            people: savedPeople,
            permissions: permissions,
            analytics: analytics,
            makePerson: person,
            isProfileActive: { [syncCoordinator] in syncCoordinator.isProfileActive },
            onContactsImported: { [snapshotStore, syncCoordinator] cards in
                guard syncCoordinator.isProfileActive, let snapshotStore else {
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
            onPersonSaved: { [weak people, snapshotStore, syncCoordinator] _ in
                guard syncCoordinator.isProfileActive else { return }
                people?.reload(people: snapshotStore?.readPeople() ?? [])
            }
        )
        let privacy = PrivacyViewController(permissions: permissions, audio: audio, analytics: analytics, snapshotStore: snapshotStore, syncCoordinator: syncCoordinator, configuration: configuration)
        let root = MainTabBarController(card: card, exchange: exchange, people: people, privacy: privacy)
        self.rootViewController = root
        root.route(to: context.entryPoint)
        syncCoordinator.onProfileDeletionPreparation = { [weak self, weak card, weak exchange, weak people, weak privacy, audio, analytics] in
            let personControllers = self?.personControllers.allObjects ?? []
            var contactInvalidations: [ContactReconciliationSessionFence.Invalidation] = []
            if let invalidation = people?.beginProfileDeletion() {
                contactInvalidations.append(invalidation)
            }
            contactInvalidations.append(contentsOf: personControllers.map {
                $0.beginProfileDeletion()
            })
            self?.cancelActiveBootstrapTask()
            self?.pushTokenTask?.cancel()
            self?.pushTokenTask = nil
            audio.delete()
            analytics.setConsent(false)
            card?.applyProfileDeletion()
            exchange?.applyProfileDeletion()
            privacy?.applyProfileDeletion()
            for invalidation in contactInvalidations {
                await invalidation.waitForInFlightCommits()
            }
        }
        syncCoordinator.onProfileReactivated = { [weak people, weak privacy] in
            people?.applyProfileReactivation()
            privacy?.applyProfileReactivation()
        }
        syncCoordinator.onAudioInvalidated = { [mediaTransfer] in
            mediaTransfer.removeAllCachedAudio()
        }
        if persistsUserChanges {
            syncCoordinator.onPeopleChanged = { [weak people, snapshotStore] in
                people?.reload(people: snapshotStore?.readPeople() ?? [])
            }
            syncCoordinator.onOwnCardChanged = { [weak card] published in card?.applyPublishedCard(published) }
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
        guard let profileContext = syncCoordinator.captureProfileOperationContext() else { return }
        pushTokenTask?.cancel()
        pushTokenTask = Task { [syncCoordinator] in
            guard !Task.isCancelled,
                  syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
            await syncCoordinator.updatePushToken(token, context: profileContext)
        }
    }

    private func refreshPeople() {
        let profileContext = syncCoordinator.captureProfileOperationContext()
        if let profileContext {
            startActiveBootstrap(context: profileContext)
            return
        }
        guard syncCoordinator.needsDeletionRecovery else { return }
        startDeletionRecoveryBootstrap()
    }

    private func startActiveBootstrap(context profileContext: ProfileOperationContext) {
        let start = bootstrapTaskOwnership.beginActive()
        cancelBootstrapTask(start.replaced)
        let ticket = start.ticket
        bootstrapTasks[ticket] = Task { [weak self, syncCoordinator] in
            defer { self?.finishBootstrapTask(ticket) }
            guard !Task.isCancelled,
                  syncCoordinator.isCurrentProfileOperationContext(profileContext) else { return }
            await syncCoordinator.bootstrap(context: profileContext)
        }
    }

    private func startDeletionRecoveryBootstrap() {
        guard let ticket = bootstrapTaskOwnership.beginDeletionRecovery() else { return }
        bootstrapTasks[ticket] = Task { [weak self, syncCoordinator] in
            defer { self?.finishBootstrapTask(ticket) }
            guard !Task.isCancelled else { return }
            guard syncCoordinator.needsDeletionRecovery else { return }
            await syncCoordinator.bootstrap(context: nil)
        }
    }

    private func cancelActiveBootstrapTask() {
        cancelBootstrapTask(bootstrapTaskOwnership.invalidateActive())
    }

    private func cancelBootstrapTask(_ ticket: ProfileBootstrapTaskOwnership.Ticket?) {
        guard let ticket else { return }
        bootstrapTasks.removeValue(forKey: ticket)?.cancel()
    }

    private func finishBootstrapTask(_ ticket: ProfileBootstrapTaskOwnership.Ticket) {
        bootstrapTaskOwnership.finish(ticket)
        bootstrapTasks.removeValue(forKey: ticket)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
