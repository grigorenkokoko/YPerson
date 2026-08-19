import Foundation

enum YPersonEntryPoint: Sendable {
    case root
    case card
    case privacy
}

struct YPersonExperienceContext: Sendable {
    let entryPoint: YPersonEntryPoint
}

enum YPersonLifecycleEvent: Sendable {
    case didEnterForeground
    case pushTokenChanged(String?)
}

@MainActor
protocol YPersonExperienceOutput: AnyObject {
    func yPersonExperienceDidRequestDismiss()
}
