import AVFAudio
import Foundation

struct RecordedGreeting {
    let url: URL
    let duration: TimeInterval
    let sizeBytes: Int
}

final class AudioGreetingController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
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
    private let legacyRecordingURL: URL
    private var committedPublicGreetingIsEnabled = false
    private var draftSelectionIsPublic: Bool?
    private var hasUncommittedDraft = false

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
        let cacheDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        draftRecordingURL = cacheDirectory.appendingPathComponent("yperson-greeting-draft.m4a")
        legacyRecordingURL = cacheDirectory.appendingPathComponent("yperson-greeting.m4a")
        super.init()
        excludeFromBackup(supportDirectory)
        try? fileManager.removeItem(at: draftRecordingURL)
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
            try? FileManager.default.removeItem(at: draftRecordingURL)
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
                discardUncommittedDraft()
                return
            }
            self.recorder = recorder
            state = .recording
            let item = DispatchWorkItem { [weak self] in self?.stopRecording() }
            stopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
        } catch { discardUncommittedDraft() }
    }

    func stopRecording() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let recorder else {
            discardUncommittedDraft()
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

    func save(isPublic: Bool) {
        guard hasUncommittedDraft,
              let greeting = validatedGreeting(at: draftRecordingURL) else {
            discardUncommittedDraft()
            return
        }
        draftSelectionIsPublic = isPublic
        let duration = greeting.duration
        state = .saved(isPublic: isPublic, duration: duration)
    }

    func commitDraftForCardSave() throws {
        guard hasUncommittedDraft, let isPublic = draftSelectionIsPublic else { return }
        let draftIsValid = validatedGreeting(at: draftRecordingURL) != nil
        if PublicGreetingCommitPolicy.shouldPromoteDraft(
            explicitPublicChoice: isPublic,
            cardSaveSucceeded: true,
            draftIsValid: draftIsValid
        ) {
            try promoteDraftToCommittedPublicGreeting()
            committedPublicGreetingIsEnabled = true
        } else if isPublic {
            throw CommitError.invalidDraft
        } else {
            committedPublicGreetingIsEnabled = false
            try? FileManager.default.removeItem(at: committedPublicGreetingURL)
        }
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
    }

    private func promoteDraftToCommittedPublicGreeting() throws {
        let data = try Data(contentsOf: draftRecordingURL, options: .mappedIfSafe)
        try data.write(to: committedPublicGreetingURL, options: .atomic)
        excludeFromBackup(committedPublicGreetingURL)
        try? FileManager.default.removeItem(at: draftRecordingURL)
    }

    func discardUncommittedDraft() {
        guard hasUncommittedDraft else { return }
        stopWorkItem?.cancel()
        stopWorkItem = nil
        recorder?.stop()
        recorder = nil
        player?.stop()
        player = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try? FileManager.default.removeItem(at: draftRecordingURL)
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
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
        committedPublicGreetingIsEnabled = false
        draftSelectionIsPublic = nil
        hasUncommittedDraft = false
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
