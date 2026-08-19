import UIKit

final class MainTabBarController: UITabBarController {
    init(card: UIViewController, exchange: UIViewController, people: UIViewController, privacy: UIViewController) {
        super.init(nibName: nil, bundle: nil)
        viewControllers = [
            Self.wrap(card, title: "Карточка", symbol: "person.text.rectangle"),
            Self.wrap(exchange, title: "Обмен", symbol: "arrow.left.arrow.right.circle.fill"),
            Self.wrap(people, title: "Люди", symbol: "person.2"),
            Self.wrap(privacy, title: "Настройки", symbol: "gearshape")
        ]
        tabBar.tintColor = YPStyle.indigo
        tabBar.backgroundColor = YPStyle.surface
    }

    func route(to entryPoint: YPersonEntryPoint) {
        switch entryPoint {
        case .root, .card:
            selectedIndex = 0
        case .privacy:
            selectedIndex = 3
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func wrap(_ controller: UIViewController, title: String, symbol: String) -> UINavigationController {
        controller.title = title
        let navigation = UINavigationController(rootViewController: controller)
        navigation.navigationBar.prefersLargeTitles = true
        navigation.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        return navigation
    }
}
