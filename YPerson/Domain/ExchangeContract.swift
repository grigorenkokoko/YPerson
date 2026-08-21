import Foundation

struct PrivateCardFields: Codable, Equatable {
    let phone: String

    init?(card: PersonCard) {
        let value = card.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return nil }
        phone = value
    }
}

struct PrivatePhoneShareConsent: Equatable {
    private(set) var isAuthorized = false

    mutating func authorize() {
        isAuthorized = true
    }

    mutating func revoke() {
        isAuthorized = false
    }

    mutating func consume(
        forPreparationMethod method: String,
        card: PersonCard
    ) -> PrivateCardFields? {
        guard method == "manual", isAuthorized else { return nil }
        isAuthorized = false
        return PrivateCardFields(card: card)
    }
}

enum PendingSyncOperationPersistencePolicy {
    static func allowsDurablePersistence(_ operation: SyncOperation) -> Bool {
        switch operation {
        case .claimExchange, .cancelExchange:
            return false
        default:
            return true
        }
    }

    static func durableOperations(
        from operations: [PendingSyncOperation]
    ) -> [PendingSyncOperation] {
        operations.filter { allowsDurablePersistence($0.request.operation) }
    }
}

enum ManualExchangeCode {
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func normalize(_ value: String) -> String? {
        let compact = value
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        let payload = compact.hasPrefix("YP") ? String(compact.dropFirst(2)) : compact
        guard payload.count == 12, payload.allSatisfy(alphabet.contains) else { return nil }
        return "YP-\(payload.prefix(4))-\(payload.dropFirst(4).prefix(4))-\(payload.dropFirst(8))"
    }
}

enum ExchangeCredential: Equatable {
    case token(String)
    case code(String)

    var exchangeToken: String? {
        if case .token(let value) = self { return value }
        return nil
    }

    var exchangeCode: String? {
        if case .code(let value) = self { return value }
        return nil
    }
}

struct PreparedExchange: Equatable {
    let credential: ExchangeCredential
    let expiresAt: Date

    enum ResolutionError: Error {
        case invalidResponse
    }

    static func resolve(
        method: String,
        exchangeToken: String?,
        exchangeCode: String?,
        expiresAt: Date?
    ) throws -> PreparedExchange {
        guard let expiresAt else { throw ResolutionError.invalidResponse }
        switch method {
        case "manual":
            guard exchangeToken == nil,
                  let exchangeCode,
                  let canonical = ManualExchangeCode.normalize(exchangeCode) else {
                throw ResolutionError.invalidResponse
            }
            return PreparedExchange(credential: .code(canonical), expiresAt: expiresAt)
        case "qr", "bluetooth", "photo":
            guard exchangeCode == nil,
                  let exchangeToken,
                  !exchangeToken.isEmpty else {
                throw ResolutionError.invalidResponse
            }
            return PreparedExchange(credential: .token(exchangeToken), expiresAt: expiresAt)
        default:
            throw ResolutionError.invalidResponse
        }
    }
}
