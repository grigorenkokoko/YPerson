import AVFAudio
import Foundation

struct RecordedGreeting {
    let url: URL
    let duration: TimeInterval
    let sizeBytes: Int
}

final class AudioGreetingController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private struct PublicDraftSelectionMarker: Codable {
        let selectionID: String
    }

    private enum CommitError: Error {
        case invalidDraft
    }

    enum State: Equatable {
        case empty
        case recording
        case preview(duration: TimeInterval)
        case playing(duration: TimeInterval)
        case saved(isPublic: Bool, duration: TimeInterval)
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var stopWorkItem: DispatchWorkItem?
    private var stateBeforeExternalPlayback: State?
    private(set) var state: State = .empty { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?
    private let committedPublicGreetingURL: URL
    private let draftRecordingURL: URL
    private let draftSelectionMarkerURL: URL
    private let legacyRecordingURL: URL
    private var committedPublicGreetingIsEnabled = false
    private var draftSelectionIsPublic: Bool?
    private var hasUncommittedDraft = false
    private var hasStagedRemoval = false

    override init() {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("YPerson", isDirectory: true)
        try? fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        committedPublicGreetingURL = supportDirectory.appendingPathComponent("greeting.m4a")
        draftSelectionMarkerURL = supportDirectory.appendingPathComponent(
            "public-greeting-draft-selection.json"
        )
        let cacheDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        draftRecordingURL = cacheDirectory.appendingPathComponent("yperson-greeting-draft.m4a")
        legacyRecordingURL = cacheDirectory.appendingPathComponent("yperson-greeting.m4a")
        super.init()
        excludeFromBackup(supportDirectory)
    }

    var pendingCardCommitIntent: AudioCardCommitIntent? {
        if hasStagedRemoval { return .removeCommitted }
        guard hasUncommittedDraft,
              draftSelectionIsPublic == true,
              let selectionID = readDraftSelectionMarker()?.selectionID else { return nil }
        return .promotePublicDraft(selectionID: selectionID)
    }

    var cardAudioDraftStatus: CardAudioDraftStatus {
        switch state {
        case .empty:
            return .empty
        case .recording, .preview, .playing:
            return .unfinished
        case .saved(isPublic: true, _):
            return .savedPublic
        case .saved(isPublic: false, _):
            return .savedPrivate
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    func requestAndRecord() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.startRecording() : self?.setUnavailable() }
            }
        } else {
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.startRecording() : self?.setUnavailable() }
            }
        }
    }

    private func startRecording() {
        do {
            draftSelectionIsPublic = nil
            hasUncommittedDraft = true
            hasStagedRemoval = false
            try? FileManager.default.removeItem(at: draftRecordingURL)
            try? FileManager.default.removeItem(at: draftSelectionMarkerURL)
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: draftRecordingURL, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                try? audioSession.setActive(false)
                discardUncommittedEdits()
                return
            }
            self.recorder = recorder
            state = .recording
            let item = DispatchWorkItem { [weak self] in self?.stopRecording() }
            stopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
        } catch { discardUncommittedEdits() }
    }

    func stopRecording() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let recorder else {
            discardUncommittedEdits()
            return
        }
        let elapsedTime = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? audioSession.setActive(false)
        let duration = (try? AVAudioPlayer(contentsOf: draftRecordingURL).duration) ?? elapsedTime
        state = duration > 0 ? .preview(duration: duration) : .empty
    }

    func play() {
        let previousState = state
        do {
            let playbackURL: URL
            switch PublicGreetingCommitPolicy.playbackSource(
                hasUncommittedDraft: hasUncommittedDraft,
                committedPublicEnabled: committedPublicGreetingIsEnabled
            ) {
            case .draft:
                playbackURL = draftRecordingURL
            case .committedPublic:
                playbackURL = committedPublicGreetingURL
            case .none:
                throw CocoaError(.fileReadNoSuchFile)
            }
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: playbackURL)
            player.delegate = self
            guard player.play() else {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                state = previousState
                return
            }
            stateBeforeExternalPlayback = previousState
            self.player = player
            state = .playing(duration: player.duration)
        } catch {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            stateBeforeExternalPlayback = nil
            state = previousState
        }
    }

    func savedGreeting() -> RecordedGreeting? {
        guard committedPublicGreetingIsEnabled else { return nil }
        return validatedCommittedPublicGreeting()
    }

    func restoreSavedPublicGreetingIfAvailable(expected: Bool) {
        let fileManager = FileManager.default
        let action = PublicGreetingCommitPolicy.restoreAction(
            expectedPublic: expected,
            committedExists: fileManager.fileExists(atPath: committedPublicGreetingURL.path),
            legacyExists: fileManager.fileExists(atPath: legacyRecordingURL.path)
        )
        guard action == .useCommitted,
              let greeting = validatedCommittedPublicGreeting() else { return }
        committedPublicGreetingIsEnabled = true
        state = .saved(isPublic: true, duration: greeting.duration)
    }

    private func validatedCommittedPublicGreeting() -> RecordedGreeting? {
        validatedGreeting(at: committedPublicGreetingURL)
    }

    private func validatedGreeting(at url: URL) -> RecordedGreeting? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= 1_048_576,
              let player = try? AVAudioPlayer(contentsOf: url),
              player.duration > 0,
              player.duration <= 10 else { return nil }
        return RecordedGreeting(url: url, duration: player.duration, sizeBytes: size)
    }

    func play(fileURL: URL) throws {
        let previousState = state
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.delegate = self
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            stateBeforeExternalPlayback = previousState
            self.player = player
            state = .playing(duration: player.duration)
        } catch {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            stateBeforeExternalPlayback = nil
            throw error
        }
    }

    func stopPlayback() {
        guard case .playing(let duration) = state else { return }
        player?.stop()
        player = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousState = stateBeforeExternalPlayback {
            stateBeforeExternalPlayback = nil
            state = previousState
        } else {
            state = .preview(duration: duration)
        }
    }

    func selectPublicDraft() throws {
        guard hasUncommittedDraft,
              let greeting = validatedGreeting(at: draftRecordingURL) else {
            discardUncommittedEdits()
            throw CommitError.invalidDraft
        }
        try writeDraftSelectionMarker(
            PublicDraftSelectionMarker(selectionID: UUID().uuidString.lowercased())
        )
        draftSelectionIsPublic = true
        let duration = greeting.duration
        state = .saved(isPublic: true, duration: duration)
    }

    func commitEditsForCardSave(
        authorizedBy record: PendingAudioCardCommitRecord?,
        currentCard: PersonCard,
        pendingOperations: [PendingSyncOperation]
    ) throws {
        guard hasUncommittedDraft || hasStagedRemoval else { return }
        guard let record,
              AudioCardCommitRecoveryPolicy.authorizes(
                  record: record,
                  markerSelectionID: readDraftSelectionMarker()?.selectionID,
                  currentCard: currentCard,
                  pendingOperations: pendingOperations
              ) else { throw CommitError.invalidDraft }
        try applyAuthorizedCardAudioCommit(record)
    }

    @discardableResult
    func recoverPendingCardAudioCommit(
        _ record: PendingAudioCardCommitRecord?,
        currentCard: PersonCard?,
        pendingOperations: [PendingSyncOperation]
    ) -> Bool {
        guard let record,
              AudioCardCommitRecoveryPolicy.authorizes(
                  record: record,
                  markerSelectionID: readDraftSelectionMarker()?.selectionID,
                  currentCard: currentCard,
                  pendingOperations: pendingOperations
              ) else {
            discardUncommittedEdits()
            return false
        }
        do {
            try applyAuthorizedCardAudioCommit(record)
            return true
        } catch {
            discardUncommittedEdits()
            return false
        }
    }

    private func applyAuthorizedCardAudioCommit(
        _ record: PendingAudioCardCommitRecord
    ) throws {
        switch record.intent.kind {
        case .promotePublicDraft:
            guard validatedGreeting(at: draftRecordingURL) != nil else {
                throw CommitError.invalidDraft
            }
            try promoteDraftToCommittedPublicGreeting()
            committedPublicGreetingIsEnabled = true
        case .removeCommitted:
            try? FileManager.default.removeItem(at: committedPublicGreetingURL)
            try? FileManager.default.removeItem(at: legacyRecordingURL)
            committedPublicGreetingIsEnabled = false
        }
        try? FileManager.default.removeItem(at: draftRecordingURL)
        try? FileManager.default.removeItem(at: draftSelectionMarkerURL)
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
        hasStagedRemoval = false
        if committedPublicGreetingIsEnabled,
           let greeting = validatedCommittedPublicGreeting() {
            state = .saved(isPublic: true, duration: greeting.duration)
        } else {
            state = .empty
        }
    }

    private func promoteDraftToCommittedPublicGreeting() throws {
        let data = try Data(contentsOf: draftRecordingURL, options: .mappedIfSafe)
        try data.write(to: committedPublicGreetingURL, options: .atomic)
        excludeFromBackup(committedPublicGreetingURL)
        try? FileManager.default.removeItem(at: draftRecordingURL)
    }

    private func writeDraftSelectionMarker(
        _ marker: PublicDraftSelectionMarker
    ) throws {
        try JSONEncoder().encode(marker).write(
            to: draftSelectionMarkerURL,
            options: .atomic
        )
    }

    private func readDraftSelectionMarker() -> PublicDraftSelectionMarker? {
        guard let data = try? Data(contentsOf: draftSelectionMarkerURL) else { return nil }
        return try? JSONDecoder().decode(PublicDraftSelectionMarker.self, from: data)
    }

    func stageRemovalForCardSave() {
        stopWorkItem?.cancel()
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        try? FileManager.default.removeItem(at: draftRecordingURL)
        try? FileManager.default.removeItem(at: draftSelectionMarkerURL)
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
        hasStagedRemoval = true
        state = .empty
    }

    func discardUncommittedEdits() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try? FileManager.default.removeItem(at: draftRecordingURL)
        try? FileManager.default.removeItem(at: draftSelectionMarkerURL)
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
        hasStagedRemoval = false
        if committedPublicGreetingIsEnabled,
           let greeting = validatedCommittedPublicGreeting() {
            state = .saved(isPublic: true, duration: greeting.duration)
        } else {
            state = .empty
        }
    }

    func delete() {
        stopWorkItem?.cancel()
        recorder?.stop()
        player?.stop()
        try? FileManager.default.removeItem(at: draftRecordingURL)
        try? FileManager.default.removeItem(at: committedPublicGreetingURL)
        try? FileManager.default.removeItem(at: legacyRecordingURL)
        try? FileManager.default.removeItem(at: draftSelectionMarkerURL)
        committedPublicGreetingIsEnabled = false
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
        hasStagedRemoval = false
        state = .empty
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousState = stateBeforeExternalPlayback {
            stateBeforeExternalPlayback = nil
            state = previousState
        } else {
            state = .preview(duration: player.duration)
        }
    }

    private func setUnavailable() { state = .empty }
    deinit { stopWorkItem?.cancel(); recorder?.stop(); player?.stop() }
}
