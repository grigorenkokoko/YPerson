import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, YPersonExperienceOutput {
    var window: UIWindow?
    private var experienceBuilder: YPersonExperienceBuilder?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureNotifications()
        let window = UIWindow(frame: UIScreen.main.bounds)
        do {
            let builder = try YPersonExperienceBuilder(
                configuration: try AppConfiguration(bundle: .main)
            )
            self.experienceBuilder = builder
            let launchURL = launchOptions?[.url] as? URL
            let entryPoint: YPersonEntryPoint = launchURL.map(ScannerWidgetRoute.matches) == true
                ? .scanQR
                : .root
            window.rootViewController = builder.makeRootViewController(
                context: YPersonExperienceContext(entryPoint: entryPoint),
                output: self
            )
        } catch {
            window.rootViewController = configurationErrorController(error)
        }
        window.makeKeyAndVisible()
        self.window = window
#if DEBUG
        if ProcessInfo.processInfo.environment["YP_ACCESSIBILITY_DUMP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.writeAccessibilityEvidence() }
        }
#endif
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard ScannerWidgetRoute.matches(url), let experienceBuilder else {
            return false
        }
        experienceBuilder.route(to: .scanQR)
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { .portrait }

    func applicationDidBecomeActive(_ application: UIApplication) {
        experienceBuilder?.handle(.didEnterForeground)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        experienceBuilder?.handle(
            .pushTokenChanged(deviceToken.map { String(format: "%02x", $0) }.joined())
        )
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Keep the last acknowledged/pending APNs token. A transient registration
        // failure is not an explicit request to remove it from the server.
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "YPERSON_BLOCK" {
            window?.rootViewController?.present(simpleAlert("Человек заблокирован", "Будущие обновления скрыты. Системные Контакты не изменены."), animated: true)
        }
        completionHandler()
    }

    private func configureNotifications() {
        let review = UNNotificationAction(identifier: "YPERSON_REVIEW", title: "Просмотреть и обновить", options: .foreground)
        let block = UNNotificationAction(identifier: "YPERSON_BLOCK", title: "Заблокировать", options: [.destructive, .authenticationRequired])
        let category = UNNotificationCategory(identifier: "YPERSON_CARD_UPDATE", actions: [review, block], intentIdentifiers: [], options: .customDismissAction)
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func configurationErrorController(_ error: Error) -> UIViewController {
        let controller = UIViewController(); controller.view.backgroundColor = YPStyle.canvas
        let label = YPStyle.label("YPerson не запущен\n\n\(error.localizedDescription)", style: .title2, weight: .bold); label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor), label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24)])
        return controller
    }

    private func simpleAlert(_ title: String, _ message: String) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); return alert
    }

    func yPersonExperienceDidRequestDismiss() {
        // The standalone experience owns the root and therefore has nothing to dismiss.
    }

#if DEBUG
    private func writeAccessibilityEvidence() {
        guard let rootView = window else { return }
        var lines = ["YPerson accessibility hierarchy"]
        appendAccessibility(from: rootView, depth: 0, lines: &lines)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yperson-accessibility.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendAccessibility(from view: UIView, depth: Int, lines: inout [String]) {
        let fallback: String? = (view as? UILabel)?.text ?? (view as? UIButton)?.title(for: .normal)
        if view.isAccessibilityElement || fallback != nil {
            let label = view.accessibilityLabel ?? fallback ?? String(describing: type(of: view))
            let value = view.accessibilityValue.map { " value=\($0)" } ?? ""
            let hint = view.accessibilityHint.map { " hint=\($0)" } ?? ""
            lines.append("\(String(repeating: "  ", count: depth))\(type(of: view)): \(label)\(value)\(hint)")
        }
        view.subviews.forEach { appendAccessibility(from: $0, depth: depth + 1, lines: &lines) }
    }
#endif
}
