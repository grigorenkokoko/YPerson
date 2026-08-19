import Foundation

struct AppConfiguration {
    enum ConfigurationError: LocalizedError {
        case missing(String)
        case invalidURL(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key): return "В конфигурации отсутствует \(key)."
            case .invalidURL(let key): return "В конфигурации указан некорректный URL: \(key)."
            }
        }
    }

    let apiBaseURL: URL
    let privacyPolicyURL: URL
    let supportURL: URL
    let appGroupIdentifier: String
    let appMetricaAPIKey: String

    init(bundle: Bundle) throws {
        func value(_ key: String) throws -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.missing(key)
            }
            return value
        }

        let apiString = try value("API_BASE_URL")
        let privacyString = try value("PRIVACY_POLICY_URL")
        let supportString = try value("SUPPORT_URL")
        guard let apiBaseURL = URL(string: apiString) else { throw ConfigurationError.invalidURL("API_BASE_URL") }
        guard let privacyPolicyURL = URL(string: privacyString) else { throw ConfigurationError.invalidURL("PRIVACY_POLICY_URL") }
        guard let supportURL = URL(string: supportString) else { throw ConfigurationError.invalidURL("SUPPORT_URL") }

        self.apiBaseURL = apiBaseURL
        self.privacyPolicyURL = privacyPolicyURL
        self.supportURL = supportURL
        self.appGroupIdentifier = try value("APP_GROUP_IDENTIFIER")
        self.appMetricaAPIKey = (bundle.object(forInfoDictionaryKey: "APPMETRICA_API_KEY") as? String) ?? ""
    }
}
