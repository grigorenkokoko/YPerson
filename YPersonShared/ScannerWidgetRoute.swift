import Foundation

enum ScannerWidgetRoute {
    static let url = URL(string: "yperson://scan")!

    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }

        return components.scheme == "yperson"
            && components.host == "scan"
            && components.path.isEmpty
            && components.query == nil
            && components.fragment == nil
            && components.user == nil
            && components.password == nil
            && components.port == nil
    }
}
