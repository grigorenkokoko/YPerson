import Foundation

struct NearbyExchangeHandshake {
    private var peerToken: String?
    private var servedOwnToken = false

    mutating func recordPeerToken(_ token: String) -> String? {
        peerToken = token
        return completedPeerToken
    }

    mutating func recordOwnTokenServed() -> String? {
        servedOwnToken = true
        return completedPeerToken
    }

    private var completedPeerToken: String? {
        servedOwnToken ? peerToken : nil
    }
}
