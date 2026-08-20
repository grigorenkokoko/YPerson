import Foundation

enum ContactReconciliationScope: Equatable {
    case complete
    case limited
}

enum ContactReconciliationAction: Equatable {
    case add
    case update
    case noChange
}

struct ContactCardProjection: Equatable {
    let name: String
    let company: String
    let role: String
    let phone: String
    let email: String
}

struct ContactProjection: Equatable {
    let identifier: String
    let givenName: String
    let familyName: String
    let company: String
    let role: String
    let phones: [String]
    let emails: [String]
}

struct ContactReconciliationCandidate: Equatable {
    let identifier: String
    let name: String
    let company: String
    let maskedPhone: String?
    let maskedEmail: String?
    let matchEvidence: [String]

    var identityDetail: String {
        var components: [String] = []
        if !company.isEmpty { components.append(company) }
        if let maskedPhone { components.append(maskedPhone) }
        if let maskedEmail { components.append(maskedEmail) }
        if !matchEvidence.isEmpty { components.append("Совпадение: \(matchEvidence.joined(separator: " и "))") }
        return components.joined(separator: " · ")
    }
}

struct ContactReconciliationPlan: Equatable {
    let action: ContactReconciliationAction
    let candidate: ContactReconciliationCandidate?
    let changedFields: [String]
    let scope: ContactReconciliationScope
    let baseline: ContactProjection?
}

enum ContactReconciliationResult: Equatable {
    case plan(ContactReconciliationPlan)
    case chooseCandidate([ContactReconciliationCandidate])
    case insufficientAccess
}

enum ContactReconciliationPlannerError: Error, Equatable, LocalizedError {
    case invalidCandidate
    case stalePlan

    var errorDescription: String? {
        switch self {
        case .invalidCandidate:
            return "Выбранный контакт больше не доступен. Запустите проверку ещё раз."
        case .stalePlan:
            return "Контакты изменились после показа плана. Проверьте обновлённый план перед сохранением."
        }
    }
}

enum ContactReconciliationPlanner {
    static func reconcile(
        card: ContactCardProjection,
        contacts: [ContactProjection],
        scope: ContactReconciliationScope,
        choosing candidateIdentifier: String? = nil
    ) throws -> ContactReconciliationResult {
        let matches = contacts.filter { contact in
            ContactMatchPolicy.matches(
                phone: card.phone,
                email: card.email,
                candidatePhones: contact.phones,
                candidateEmails: contact.emails
            )
        }

        if let candidateIdentifier {
            guard let selected = matches.first(where: { $0.identifier == candidateIdentifier }) else {
                throw ContactReconciliationPlannerError.invalidCandidate
            }
            return .plan(plan(card: card, contact: selected, scope: scope))
        }

        guard !matches.isEmpty else {
            if scope == .limited { return .insufficientAccess }
            return .plan(ContactReconciliationPlan(
                action: .add,
                candidate: nil,
                changedFields: fieldsForNewContact(card),
                scope: scope,
                baseline: nil
            ))
        }
        if matches.count > 1 {
            return .chooseCandidate(matches.map { candidate(card: card, contact: $0) })
        }
        return .plan(plan(card: card, contact: matches[0], scope: scope))
    }

    static func projectedContact(applying card: ContactCardProjection, to contact: ContactProjection) -> ContactProjection {
        var givenName = contact.givenName
        var familyName = contact.familyName
        let names = splitName(card.name)
        if !names.given.isEmpty { givenName = names.given }
        if !names.family.isEmpty { familyName = names.family }

        let cardCompany = trimmed(card.company)
        let company = cardCompany.isEmpty ? contact.company : cardCompany
        let cardRole = trimmed(card.role)
        let role = cardRole.isEmpty ? contact.role : cardRole

        var phones = contact.phones
        if let phone = ContactMatchPolicy.normalizedPhone(card.phone), !phones.contains(where: { existing in
            ContactMatchPolicy.normalizedPhone(existing) == phone || ContactMatchPolicy.phoneMatches(existing, card.phone)
        }) {
            phones.append(trimmed(card.phone))
        }
        var emails = contact.emails
        if let email = ContactMatchPolicy.normalizedEmail(card.email), !emails.contains(where: { existing in
            ContactMatchPolicy.normalizedEmail(existing) == email
        }) {
            emails.append(trimmed(card.email))
        }
        return ContactProjection(
            identifier: contact.identifier,
            givenName: givenName,
            familyName: familyName,
            company: company,
            role: role,
            phones: phones,
            emails: emails
        )
    }

    static func validate(
        _ plan: ContactReconciliationPlan,
        card: ContactCardProjection,
        contacts: [ContactProjection]
    ) throws {
        do {
            let current = try reconcile(
                card: card,
                contacts: contacts,
                scope: plan.scope,
                choosing: plan.candidate?.identifier
            )
            guard case .plan(let currentPlan) = current, currentPlan == plan else {
                throw ContactReconciliationPlannerError.stalePlan
            }
        } catch {
            throw ContactReconciliationPlannerError.stalePlan
        }
    }

    private static func plan(
        card: ContactCardProjection,
        contact: ContactProjection,
        scope: ContactReconciliationScope
    ) -> ContactReconciliationPlan {
        let fields = changedFields(card: card, contact: contact)
        return ContactReconciliationPlan(
            action: fields.isEmpty ? .noChange : .update,
            candidate: candidate(card: card, contact: contact),
            changedFields: fields,
            scope: scope,
            baseline: contact
        )
    }

    private static func changedFields(card: ContactCardProjection, contact: ContactProjection) -> [String] {
        let names = splitName(card.name)
        var fields: [String] = []
        if (!names.given.isEmpty && names.given != contact.givenName)
            || (!names.family.isEmpty && names.family != contact.familyName) {
            fields.append("Имя")
        }
        let company = trimmed(card.company)
        if !company.isEmpty, company != contact.company { fields.append("Компания") }
        let role = trimmed(card.role)
        if !role.isEmpty, role != contact.role { fields.append("Должность") }
        if let phone = ContactMatchPolicy.normalizedPhone(card.phone), !contact.phones.contains(where: { existing in
            ContactMatchPolicy.normalizedPhone(existing) == phone || ContactMatchPolicy.phoneMatches(existing, card.phone)
        }) {
            fields.append("Телефон")
        }
        if let email = ContactMatchPolicy.normalizedEmail(card.email), !contact.emails.contains(where: { existing in
            ContactMatchPolicy.normalizedEmail(existing) == email
        }) {
            fields.append("Email")
        }
        return fields
    }

    private static func fieldsForNewContact(_ card: ContactCardProjection) -> [String] {
        var fields: [String] = []
        if !trimmed(card.name).isEmpty { fields.append("Имя") }
        if !trimmed(card.company).isEmpty { fields.append("Компания") }
        if !trimmed(card.role).isEmpty { fields.append("Должность") }
        if ContactMatchPolicy.normalizedPhone(card.phone) != nil { fields.append("Телефон") }
        if ContactMatchPolicy.normalizedEmail(card.email) != nil { fields.append("Email") }
        return fields
    }

    private static func candidate(card: ContactCardProjection, contact: ContactProjection) -> ContactReconciliationCandidate {
        let name = [contact.givenName, contact.familyName]
            .map(trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var evidence: [String] = []
        if contact.phones.contains(where: { ContactMatchPolicy.phoneMatches(card.phone, $0) }) { evidence.append("телефон") }
        if contact.emails.contains(where: { ContactMatchPolicy.emailMatches(card.email, $0) }) { evidence.append("email") }
        return ContactReconciliationCandidate(
            identifier: contact.identifier,
            name: name.isEmpty ? (trimmed(contact.company).isEmpty ? "Без имени" : trimmed(contact.company)) : name,
            company: trimmed(contact.company),
            maskedPhone: contact.phones.first.flatMap(ContactIdentityFormatter.maskedPhone),
            maskedEmail: contact.emails.first.flatMap(ContactIdentityFormatter.maskedEmail),
            matchEvidence: evidence
        )
    }

    private static func splitName(_ name: String) -> (given: String, family: String) {
        let names = name.split(separator: " ", maxSplits: 1).map(String.init)
        return (
            names.first.map(trimmed) ?? "",
            names.count > 1 ? trimmed(names[1]) : ""
        )
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
