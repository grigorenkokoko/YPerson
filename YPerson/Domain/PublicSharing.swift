import Foundation

struct PublicContactReply: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let email: String?
    let phone: String?
    let createdAt: Date
}
