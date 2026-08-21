import AVFAudio
import Foundation

struct RecordedGreeting {
    let url: URL
    let duration: TimeInterval
    let sizeBytes: Int
}

final class AudioGreetingController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
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
    private let recordingURL: URL
    private let legacyRecordingURL: URL

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
        recordingURL = supportDirectory.appendingPathComponent("greeting.m4a")
        legacyRecordingURL = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("yperson-greeting.m4a")
        super.init()
        excludeFromBackup(supportDirectory)
        migrateLegacyRecordingIfNeeded()
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

    private func migrateLegacyRecordingIfNeeded() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: recordingURL.path) {
            excludeFromBackup(recordingURL)
            return
        }
        guard fileManager.fileExists(atPath: legacyRecordingURL.path) else { return }
        do {
            try fileManager.moveItem(at: legacyRecordingURL, to: recordingURL)
        } catch {
            if (try? fileManager.copyItem(at: legacyRecordingURL, to: recordingURL)) != nil {
                try? fileManager.removeItem(at: legacyRecordingURL)
            }
        }
        if fileManager.fileExists(atPath: recordingURL.path) {
            excludeFromBackup(recordingURL)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    private var readableRecordingURL: URL {
        FileManager.default.fileExists(atPath: recordingURL.path)
            ? recordingURL
            : legacyRecordingURL
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
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                try? audioSession.setActive(false)
                state = .empty
                return
            }
            self.recorder = recorder
            state = .recording
            let item = DispatchWorkItem { [weak self] in self?.stopRecording() }
            stopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
        } catch { state = .empty }
    }

    func stopRecording() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let recorder else {
            state = .empty
            return
        }
        let elapsedTime = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? audioSession.setActive(false)
        excludeFromBackup(recordingURL)
        let duration = (try? AVAudioPlayer(contentsOf: recordingURL).duration) ?? elapsedTime
        state = duration > 0 ? .preview(duration: duration) : .empty
    }

    func play() {
        do {
            stateBeforeExternalPlayback = nil
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: readableRecordingURL)
            player.delegate = self
            guard player.play() else {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                state = .empty
                return
            }
            self.player = player
            state = .playing(duration: player.duration)
        } catch {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            state = .empty
        }
    }

    func savedGreeting() -> RecordedGreeting? {
        guard case .saved(isPublic: true, _) = state else { return nil }
        return validatedGreeting()
    }

    func restoreSavedPublicGreetingIfAvailable(expected: Bool) {
        guard expected, let greeting = validatedGreeting() else { return }
        state = .saved(isPublic: true, duration: greeting.duration)
    }

    private func validatedGreeting() -> RecordedGreeting? {
        let readableURL = readableRecordingURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: readableURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= 1_048_576,
              let player = try? AVAudioPlayer(contentsOf: readableURL),
              player.duration > 0,
              player.duration <= 10 else { return nil }
        return RecordedGreeting(url: readableURL, duration: player.duration, sizeBytes: size)
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
        let duration = (try? AVAudioPlayer(contentsOf: readableRecordingURL).duration) ?? 0
        state = .saved(isPublic: isPublic, duration: duration)
    }

    func delete() {
        stopWorkItem?.cancel()
        recorder?.stop()
        player?.stop()
        try? FileManager.default.removeItem(at: recordingURL)
        try? FileManager.default.removeItem(at: legacyRecordingURL)
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
