import Foundation

/// Parses the small, local-only vCard subset that YPerson can import from QR and Photos.
enum VCardParser {
    /// A scan candidate is capped at 64 KiB before any parsing work is performed.
    static let maximumInputBytes = 64 * 1024

    static func isCandidate(_ value: String) -> Bool {
        let firstLine = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return firstLine == "BEGIN:VCARD"
    }

    static func parse(_ value: String) throws -> PersonCard {
        guard value.utf8.count <= maximumInputBytes else { throw ParseError.malformed }

        let lines = unfold(value)
        guard lines.count >= 2,
              lines.first?.caseInsensitiveCompare("BEGIN:VCARD") == .orderedSame,
              lines.last?.caseInsensitiveCompare("END:VCARD") == .orderedSame else {
            throw ParseError.malformed
        }

        var fields = Fields()
        for line in lines.dropFirst().dropLast() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator]
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard let name else { continue }
            let value = String(line[line.index(after: separator)...])
            fields.apply(name: name, value: value)
        }

        let name = fields.fullName
        guard !name.isEmpty else { throw ParseError.malformed }

        return PersonCard(
            id: UUID().uuidString.lowercased(),
            name: name,
            role: fields.role,
            company: fields.company,
            phone: fields.phone,
            email: fields.email,
            tagline: fields.tagline,
            hasAudioGreeting: false,
            meetingPlace: nil,
            isBlocked: false,
            sourceInstallationID: nil,
            syncState: .localOnly
        )
    }

    enum ParseError: LocalizedError {
        case malformed

        var errorDescription: String? {
            "Визитка vCard повреждена, слишком велика или не содержит имени."
        }
    }

    private struct Fields {
        var formattedName = ""
        var structuredName = ""
        var company = ""
        var role = ""
        var phone = ""
        var email = ""
        var tagline = ""

        var fullName: String {
            firstUsable(formattedName, structuredName)
        }

        mutating func apply(name: String, value: String) {
            switch name {
            case "FN":
                formattedName = firstUsable(formattedName, unescape(value))
            case "N":
                structuredName = firstUsable(structuredName, structuredName(from: value))
            case "ORG":
                company = firstUsable(company, firstComponent(of: value))
            case "TITLE":
                role = firstUsable(role, unescape(value))
            case "TEL":
                phone = firstUsable(phone, unescape(value))
            case "EMAIL":
                email = firstUsable(email, unescape(value))
            case "NOTE":
                tagline = firstUsable(tagline, unescape(value))
            default:
                break
            }
        }

        private func structuredName(from value: String) -> String {
            let components = splitUnescaped(value, separator: ";").map(unescape)
            let family = components.indices.contains(0) ? components[0] : ""
            let given = components.indices.contains(1) ? components[1] : ""
            let additional = components.indices.contains(2) ? components[2] : ""
            let prefix = components.indices.contains(3) ? components[3] : ""
            let suffix = components.indices.contains(4) ? components[4] : ""
            return [prefix, given, additional, family, suffix]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private func firstComponent(of value: String) -> String {
            unescape(splitUnescaped(value, separator: ";").first ?? "")
        }

        private func firstUsable(_ current: String, _ candidate: String) -> String {
            current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                : current
        }
    }

    private static func unfold(_ value: String) -> [String] {
        var lines: [String] = []
        for rawLine in value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private static func splitUnescaped(_ value: String, separator: Character) -> [String] {
        var components: [String] = [""]
        var escaping = false
        for character in value {
            if escaping {
                components[components.count - 1].append(character)
                escaping = false
            } else if character == "\\" {
                components[components.count - 1].append(character)
                escaping = true
            } else if character == separator {
                components.append("")
            } else {
                components[components.count - 1].append(character)
            }
        }
        return components
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                case "\\", ",", ";": result.append(character)
                default:
                    result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }
}
