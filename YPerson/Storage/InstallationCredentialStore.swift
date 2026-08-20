import Foundation
import Security

struct InstallationCredential: Codable, Equatable {
    let installationID: String
    let bearer: String
}

final class InstallationCredentialStore {
    enum CredentialError: LocalizedError {
        case keychain(OSStatus)
        case corruptedCredential
        case randomGeneration(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain:
                return "Не удалось получить защищённые данные установки."
            case .corruptedCredential:
                return "Защищённые данные установки повреждены."
            case .randomGeneration:
                return "Не удалось безопасно создать данные установки."
            }
        }
    }

    private let service: String
    private let account = "installation-credential-v2"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String) {
        self.service = service
    }

    func credential() throws -> InstallationCredential {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let stored = try? decoder.decode(InstallationCredential.self, from: data),
                  UUID(uuidString: stored.installationID)?.uuidString.lowercased() == stored.installationID,
                  !stored.bearer.contains("="),
                  let bearerData = Base64URL.decode(stored.bearer),
                  bearerData.count == 32,
                  Base64URL.encode(bearerData) == stored.bearer else {
                throw CredentialError.corruptedCredential
            }
            return stored
        case errSecItemNotFound:
            return try createCredential()
        default:
            throw CredentialError.keychain(status)
        }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

    private func createCredential() throws -> InstallationCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw CredentialError.randomGeneration(randomStatus)
        }
        let created = InstallationCredential(
            installationID: UUID().uuidString.lowercased(),
            bearer: Base64URL.encode(Data(bytes))
        )
        var query = baseQuery
        query[kSecValueData as String] = try encoder.encode(created)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return try credential()
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        return created
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var readQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
