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

    private var recordingURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("yperson-greeting.m4a")
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
        let duration = (try? AVAudioPlayer(contentsOf: recordingURL).duration) ?? elapsedTime
        state = duration > 0 ? .preview(duration: duration) : .empty
    }

    func play() {
        do {
            stateBeforeExternalPlayback = nil
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(contentsOf: recordingURL)
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
        guard case .saved(isPublic: true, _) = state,
              let attributes = try? FileManager.default.attributesOfItem(atPath: recordingURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= 1_048_576,
              let player = try? AVAudioPlayer(contentsOf: recordingURL),
              player.duration > 0,
              player.duration <= 10 else { return nil }
        return RecordedGreeting(url: recordingURL, duration: player.duration, sizeBytes: size)
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
        let duration = (try? AVAudioPlayer(contentsOf: recordingURL).duration) ?? 0
        state = .saved(isPublic: isPublic, duration: duration)
    }

    func delete() {
        stopWorkItem?.cancel()
        recorder?.stop()
        player?.stop()
        try? FileManager.default.removeItem(at: recordingURL)
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
