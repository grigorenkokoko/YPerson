import Foundation

enum ContactIdentityFormatter {
    static func savedCardChoiceLabel(
        name: String,
        role: String,
        company: String,
        phone: String,
        email: String
    ) -> String {
        var components = [name, role, company]
            .map(trimmed)
            .filter { !$0.isEmpty }
        if let phone = maskedPhone(phone) { components.append(phone) }
        if let email = maskedEmail(email) { components.append(email) }
        return components.joined(separator: " · ")
    }

    static func maskedPhone(_ value: String) -> String? {
        guard let digits = ContactMatchPolicy.normalizedPhone(value) else { return nil }
        let suffix = digits.count >= 4 ? String(digits.suffix(4)) : ""
        return suffix.isEmpty ? "Телефон ••••" : "Телефон •••• \(suffix)"
    }

    static func maskedEmail(_ value: String) -> String? {
        guard let email = ContactMatchPolicy.normalizedEmail(value) else { return nil }
        let components = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard components.count == 2, let first = components[0].first else { return "Email ••••" }
        return "Email \(first)•••@\(components[1])"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
