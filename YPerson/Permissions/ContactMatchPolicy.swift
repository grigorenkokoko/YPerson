import Foundation

enum ContactMatchPolicy {
    static func phoneMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = normalizedPhone(lhs), let rhs = normalizedPhone(rhs) else { return false }
        if lhs.count >= 10, rhs.count >= 10 {
            return lhs.suffix(10) == rhs.suffix(10)
        }
        guard (7...9).contains(lhs.count), (7...9).contains(rhs.count) else { return false }
        return lhs == rhs
    }

    static func emailMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = normalizedEmail(lhs), let rhs = normalizedEmail(rhs) else { return false }
        return lhs == rhs
    }

    static func matches(phone: String, email: String, candidatePhones: [String], candidateEmails: [String]) -> Bool {
        candidatePhones.contains { phoneMatches(phone, $0) }
            || candidateEmails.contains { emailMatches(email, $0) }
    }

    static func normalizedPhone(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    static func normalizedEmail(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
