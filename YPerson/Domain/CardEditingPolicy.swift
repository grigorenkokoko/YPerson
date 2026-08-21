import Foundation

enum CardAudioDraftStatus {
    case empty
    case unfinished
    case savedPublic
    case savedPrivate
}

enum CardEditingPolicy {
    static func canFinish(audioStatus: CardAudioDraftStatus) -> Bool {
        audioStatus != .unfinished
    }

    static func hasShareableAudio(
        audioStatus: CardAudioDraftStatus,
        existingHasShareableAudio: Bool,
        audioWasEdited: Bool
    ) -> Bool {
        guard audioWasEdited else { return existingHasShareableAudio }
        return audioStatus == .savedPublic
    }
}
