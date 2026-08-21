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

enum PersonSyncState: String, Codable {
    case localOnly
    case pending
    case synced
}

struct CardTemplateDefinition: Equatable {
    let id: String
    let title: String
    let sponsoredCategory: String?
}

enum CardTemplateCatalog {
    static let standardClean = CardTemplateDefinition(id: "standard-clean", title: "Чистый", sponsoredCategory: nil)
    static let standardContrast = CardTemplateDefinition(id: "standard-contrast", title: "Контрастный", sponsoredCategory: nil)
    static let mintConference = CardTemplateDefinition(id: "mint-conference", title: "Mint Conference", sponsoredCategory: "sponsored_event")
    static let indigoStudio = CardTemplateDefinition(id: "indigo-studio", title: "Indigo Studio", sponsoredCategory: "sponsored_studio")
    static let all = [standardClean, standardContrast, mintConference, indigoStudio]

    static func resolve(_ id: String?) -> CardTemplateDefinition {
        all.first(where: { $0.id == id }) ?? standardClean
    }
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
    var templateID: String
    var version: Int
    var sourceInstallationID: String?
    var syncState: PersonSyncState

    init(
        id: String,
        name: String,
        role: String,
        company: String,
        phone: String,
        email: String,
        tagline: String,
        hasAudioGreeting: Bool,
        meetingPlace: String?,
        isBlocked: Bool,
        templateID: String = CardTemplateCatalog.standardClean.id,
        version: Int = 1,
        sourceInstallationID: String? = nil,
        syncState: PersonSyncState = .localOnly
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.company = company
        self.phone = phone
        self.email = email
        self.tagline = tagline
        self.hasAudioGreeting = hasAudioGreeting
        self.meetingPlace = meetingPlace
        self.isBlocked = isBlocked
        self.templateID = templateID
        self.version = max(1, version)
        self.sourceInstallationID = sourceInstallationID
        self.syncState = syncState
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, company, phone, email, tagline
        case hasAudioGreeting, meetingPlace, isBlocked, version
        case sourceInstallationID, syncState, templateID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(String.self, forKey: .role)
        company = try container.decode(String.self, forKey: .company)
        phone = try container.decode(String.self, forKey: .phone)
        email = try container.decode(String.self, forKey: .email)
        tagline = try container.decode(String.self, forKey: .tagline)
        hasAudioGreeting = try container.decode(Bool.self, forKey: .hasAudioGreeting)
        meetingPlace = try container.decodeIfPresent(String.self, forKey: .meetingPlace)
        isBlocked = try container.decode(Bool.self, forKey: .isBlocked)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
            ?? CardTemplateCatalog.standardClean.id
        version = max(1, try container.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        sourceInstallationID = try container.decodeIfPresent(String.self, forKey: .sourceInstallationID)
        syncState = try container.decodeIfPresent(PersonSyncState.self, forKey: .syncState) ?? .localOnly
    }

    var exchangeCopy: PersonCard {
        var copy = self
        copy.phone = ""
        copy.meetingPlace = nil
        return copy
    }

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
    case prepareExchange
    case claimExchange
    case cancelExchange
    case prepareAudioUpload
    case updatePushToken
    case removePushToken
    case deleteProfile
    case report
    case block
}

struct SyncRequest: Codable, Equatable {
    let contractVersion: Int
    let operationID: String
    let apnsToken: String?
    let operation: SyncOperation
    let cursor: String?
    let card: PersonCard?
    let exchangeToken: String?
    let exchangeMethod: String?
    let audioAssetID: String?
    let audioSizeBytes: Int?
    let audioDurationMS: Int?
    let moderationCategory: String?
    let subjectInstallationID: String?

    init(
        apnsToken: String? = nil,
        operation: SyncOperation,
        operationID: String = UUID().uuidString.lowercased(),
        cursor: String? = nil,
        card: PersonCard? = nil,
        exchangeToken: String? = nil,
        exchangeMethod: String? = nil,
        audioAssetID: String? = nil,
        audioSizeBytes: Int? = nil,
        audioDurationMS: Int? = nil,
        moderationCategory: String? = nil,
        subjectInstallationID: String? = nil
    ) {
        self.contractVersion = 2
        self.apnsToken = apnsToken
        self.operation = operation
        self.operationID = operationID
        self.cursor = cursor
        self.card = card
        self.exchangeToken = exchangeToken
        self.exchangeMethod = exchangeMethod
        self.audioAssetID = audioAssetID
        self.audioSizeBytes = audioSizeBytes
        self.audioDurationMS = audioDurationMS
        self.moderationCategory = moderationCategory
        self.subjectInstallationID = subjectInstallationID
    }

    var isMutation: Bool { operation != .refresh }
}

struct PendingSyncOperation: Codable, Equatable, Identifiable {
    let request: SyncRequest
    let expiresAt: Date?
    let localCardID: String?

    var id: String { request.operationID }
}

struct SyncResponse: Codable {
    let accepted: Bool
    let serverVersion: String
    let updateCount: Int
    let message: String
    let nextCursor: String?
    let ownCardVersion: Int?
    let people: [SyncedPerson]
    let revokedCardIDs: [String]
    let exchangeToken: String?
    let audioUpload: AudioUpload?
    let notificationConfiguration: [String: Bool]?
}

struct AudioAsset: Codable, Equatable {
    let assetID: String
    let downloadURL: URL
    let expiresAt: Date
}

struct AudioUpload: Codable, Equatable {
    let assetID: String
    let uploadURL: URL
    let expiresAt: Date
}

struct SyncedPerson: Codable, Equatable {
    let installationID: String
    let card: PersonCard
    let version: Int
    let audio: AudioAsset?

    var versionedCard: PersonCard {
        var result = card
        result.version = max(1, version)
        result.sourceInstallationID = installationID
        result.syncState = .synced
        return result
    }
}

struct ExchangePayload: Codable, Equatable {
    let version: Int
    let issuerInstallationID: String
    let card: PersonCard
    let exchangeToken: String?
    let expiresAt: Date?
}

enum ImportedCardPersistence {
    static func card(
        from payload: ExchangePayload,
        allowsCloudClaim: Bool,
        meetingPlace: String?
    ) -> PersonCard {
        var localCard = payload.card
        localCard.sourceInstallationID = nil
        localCard.syncState = allowsCloudClaim ? .pending : .localOnly
        localCard.meetingPlace = meetingPlace
        return localCard
    }
}

enum ExchangePayloadCodec {
    private static let prefix = "yperson:v2:"

    static func encode(_ payload: ExchangePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return prefix + Base64URL.encode(try encoder.encode(payload))
    }

    static func decode(_ value: String) throws -> ExchangePayload {
        guard value.hasPrefix(prefix), value.utf8.count <= 8_192 else {
            throw PayloadError.invalidFormat
        }
        let encoded = String(value.dropFirst(prefix.count))
        guard !encoded.isEmpty,
              !encoded.contains("="),
              let data = Base64URL.decode(encoded),
              Base64URL.encode(data) == encoded else { throw PayloadError.invalidFormat }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExchangePayload.self, from: data)
        guard payload.version == 2 else { throw PayloadError.unsupportedVersion }
        guard UUID(uuidString: payload.issuerInstallationID)?.uuidString.lowercased()
                == payload.issuerInstallationID,
              !payload.card.id.isEmpty,
              payload.card.id.utf8.count <= 128,
              !payload.card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.card.name.utf8.count <= 256,
              payload.card.role.utf8.count <= 256,
              payload.card.company.utf8.count <= 256 else {
            throw PayloadError.invalidFormat
        }
        switch (payload.exchangeToken, payload.expiresAt) {
        case (nil, nil):
            break
        case let (token?, expiry?):
            guard !token.isEmpty,
                  !token.contains("="),
                  token.utf8.count == 43,
                  let tokenData = Base64URL.decode(token),
                  tokenData.count == 32,
                  Base64URL.encode(tokenData) == token,
                  expiry.timeIntervalSince1970.isFinite else {
                throw PayloadError.invalidFormat
            }
        default:
            throw PayloadError.invalidFormat
        }
        var card = payload.card
        card.sourceInstallationID = nil
        card.syncState = .localOnly
        return ExchangePayload(
            version: payload.version,
            issuerInstallationID: payload.issuerInstallationID,
            card: card,
            exchangeToken: payload.exchangeToken,
            expiresAt: payload.expiresAt
        )
    }

    enum PayloadError: LocalizedError {
        case invalidFormat
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "QR-код YPerson повреждён или имеет неизвестный формат."
            case .unsupportedVersion: return "Эта версия QR-кода пока не поддерживается."
            }
        }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        let remainder = value.count % 4
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding)
    }
}

struct SyncWireRequest: Encodable {
    let contractVersion: Int
    let operationID: String
    let installationID: String
    let apnsToken: String?
    let operation: SyncOperation
    let cursor: String?
    let card: SyncWirePersonCard?
    let exchangeToken: String?
    let exchangeMethod: String?
    let audioAssetID: String?
    let audioSizeBytes: Int?
    let audioDurationMS: Int?
    let moderationCategory: String?
    let subjectInstallationID: String?
}

struct SyncWirePersonCard: Codable {
    let id: String
    let name: String
    let role: String
    let company: String
    let phone: String
    let email: String
    let tagline: String
    let hasAudioGreeting: Bool
    let meetingPlace: String?
    let isBlocked: Bool
    let templateID: String

    init(_ card: PersonCard) {
        id = card.id
        name = card.name
        role = card.role
        company = card.company
        phone = card.phone
        email = card.email
        tagline = card.tagline
        hasAudioGreeting = card.hasAudioGreeting
        meetingPlace = nil
        isBlocked = card.isBlocked
        templateID = card.templateID
    }
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
