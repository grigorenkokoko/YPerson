import Foundation
import Security

enum PublicLinkToken {
    enum TokenError: Error {
        case randomGenerationFailed(OSStatus)
    }

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenError.randomGenerationFailed(status)
        }
        let token = encode(Data(bytes))
        precondition(token.utf8.count == 43)
        return token
    }

    static func isValid(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              !value.contains("="),
              let data = decode(value),
              data.count == 32 else {
            return false
        }
        return encode(data) == value
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> Data? {
        let paddingCount = (4 - value.count % 4) % 4
        let padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: paddingCount)
        return Data(base64Encoded: padded)
    }
}

enum PublicCardRoute {
    enum RouteError: Error {
        case invalidBaseURL
        case invalidToken
    }

    static func url(baseURL: URL, token: String) throws -> URL {
        guard PublicLinkToken.isValid(token) else { throw RouteError.invalidToken }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw RouteError.invalidBaseURL
        }
        components.percentEncodedPath = "/p/\(token)"
        guard let url = components.url else { throw RouteError.invalidBaseURL }
        return url
    }

    static func token(from url: URL, allowedHost: String) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = components.host,
              host.caseInsensitiveCompare(allowedHost) == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].isEmpty,
              parts[1] == "p" else {
            return nil
        }
        let token = String(parts[2])
        return PublicLinkToken.isValid(token) ? token : nil
    }
}
