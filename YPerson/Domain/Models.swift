import Foundation

struct FeatureAvailability: Codable, Equatable {
    let nearbyExchange: Bool
    let sponsoredTemplates: Bool
    let remoteNotifications: Bool
}
struct SponsoredTemplate: Codable, Equatable {
    let id: String
    let title: String
    let accentHex: String
}

struct RemoteConfiguration: Codable, Equatable {
    let version: String
    let minimumContract: Int
    let maintenance: Bool
    let features: FeatureAvailability
    let sponsoredTemplates: [SponsoredTemplate]
    let privacyURL: URL
    let supportURL: URL
    let moderationCategories: [String]
    let analyticsKillSwitch: Bool
}

struct PersonCard: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var role: String
    var company: String
    var phone: String
    var email: String
    var tagline: String
    var hasAudioGreeting: Bool
    var meetingPlace: String?
    var isBlocked: Bool

#if DEBUG
    static let reviewAlexey = PersonCard(
        id: "person-alexey",
        name: "Алексей Морозов",
        role: "Product Lead",
        company: "North Star",
        phone: "+7 900 555-01-02",
        email: "alexey@example.com",
        tagline: "Создаю продукты, которые соединяют людей.",
        hasAudioGreeting: false,
        meetingPlace: nil,
        isBlocked: false
    )

    static let reviewMaria = PersonCard(
        id: "person-maria",
        name: "Мария Орлова",
        role: "Founder",
        company: "Orlova Studio",
        phone: "+7 900 555-03-04",
        email: "maria@example.com",
        tagline: "Соединяю людей и полезные идеи.",
        hasAudioGreeting: false,
        meetingPlace: nil,
        isBlocked: false
    )

    static let reviewOwn = PersonCard(
        id: "person-anna",
        name: "Анна Смирнова",
        role: "Product Designer",
        company: "YPerson Studio",
        phone: "+7 900 555-10-20",
        email: "hello@example.com",
        tagline: "Помогаю сложным идеям становиться ясными.",
        hasAudioGreeting: true,
        meetingPlace: nil,
        isBlocked: false
    )
#endif
}

enum SyncOperation: String, Codable {
    case refresh
    case publishCard
    case claimExchange
    case updatePushToken
    case removePushToken
    case deleteProfile
    case report
    case block
}

struct SyncRequest: Codable {
    let installationID: String
    let bearer: String?
    let apnsToken: String?
    let operation: SyncOperation
    let card: PersonCard?
    let exchangeToken: String?
    let moderationCategory: String?
}

struct SyncResponse: Codable {
    let accepted: Bool
    let serverVersion: String
    let updateCount: Int
    let message: String
}

enum AnalyticsEvent {
    case launch
    case cardCreated
    case exchangeStarted(String)
    case cardReceived(String)
    case contactSaved
    case cardUpdateOpened
    case sponsoredTemplateViewed(String)
    case sponsoredTemplateSelected(String)

    var name: String {
        switch self {
        case .launch: return "launch"
        case .cardCreated: return "card_created"
        case .exchangeStarted: return "exchange_started"
        case .cardReceived: return "card_received"
        case .contactSaved: return "contact_saved"
        case .cardUpdateOpened: return "card_update_opened"
        case .sponsoredTemplateViewed: return "sponsored_template_viewed"
        case .sponsoredTemplateSelected: return "sponsored_template_selected"
        }
    }

    var parameters: [String: String]? {
        switch self {
        case .exchangeStarted(let method), .cardReceived(let method): return ["method": method]
        case .sponsoredTemplateViewed(let category), .sponsoredTemplateSelected(let category): return ["category": category]
        default: return nil
        }
    }
}
