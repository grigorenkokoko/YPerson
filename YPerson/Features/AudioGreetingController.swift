import AVFAudio
import Foundation

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
    private(set) var state: State = .empty { didSet { onStateChange?(state) } }
    var onStateChange: ((State) -> Void)?

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
            player = try AVAudioPlayer(contentsOf: recordingURL)
            player?.delegate = self
            player?.play()
            state = .playing(duration: player?.duration ?? 0)
        } catch { state = .empty }
    }

    func stopPlayback() {
        guard case .playing(let duration) = state else { return }
        player?.stop()
        player = nil
        state = .preview(duration: duration)
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
        state = .preview(duration: player.duration)
    }

    private func setUnavailable() { state = .empty }
    deinit { stopWorkItem?.cancel(); recorder?.stop(); player?.stop() }
}
