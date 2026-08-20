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
    private let nearby = NearbyExchangeController()
    private let photoScanner = PhotoCardScanner()
    private let audio = AudioGreetingController()
    private let imageSaver = CardImageSaver()
    private weak var output: (any YPersonExperienceOutput)?
    private weak var rootViewController: MainTabBarController?

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
        self.syncCoordinator = try SyncCoordinator(
            baseURL: configuration.apiBaseURL,
            session: session,
            snapshotStore: store,
            credentialStore: credentialStore
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
        let makeAppearance = { [permissions, analytics] in AppearanceViewController(permissions: permissions, analytics: analytics) }
        let makeEditor: (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController = { [permissions, audio] card, onSave in
            CardEditorViewController(card: card, permissions: permissions, audio: audio, makeAppearance: makeAppearance, onSave: onSave)
        }
        let card = CardViewController(card: ownCard, persistsChanges: !usesReviewFixtures, permissions: permissions, audio: audio, imageSaver: imageSaver, syncCoordinator: syncCoordinator, analytics: analytics, snapshotStore: snapshotStore, makeEditor: makeEditor)
        let person = { [permissions, imageSaver, syncCoordinator, analytics, snapshotStore] card in
            PersonViewController(card: card, permissions: permissions, imageSaver: imageSaver, syncCoordinator: syncCoordinator, analytics: analytics, snapshotStore: snapshotStore)
        }
        let people = PeopleViewController(people: savedPeople, permissions: permissions, analytics: analytics, makePerson: person)
        let exchange = ExchangeViewController(
            nearby: nearby,
            photoScanner: photoScanner,
            permissions: permissions,
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
        root.route(to: context.entryPoint)
        if !usesReviewFixtures {
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
    private func applyVerificationState(to root: MainTabBarController, card: CardViewController, exchange: ExchangeViewController, privacy: PrivacyViewController, makePerson: @escaping (PersonCard) -> UIViewController, makeEditor: @escaping (PersonCard?, @escaping (PersonCard) -> Void) -> UIViewController, makeAppearance: @escaping () -> UIViewController) {
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
                    navigation?.pushViewController(makeAppearance(), animated: false)
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
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
