import AVFoundation
import Speech
import UIKit
import Observation

@MainActor @Observable
final class LocalCaptureAudio: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var playingID: UUID?
    private(set) var transcribingID: UUID?
    var notice: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func interrupted() {
        stop()
        notice = "Audio stopped by an interruption. Any recorded audio is kept."
    }

    @objc private func backgrounded() { stop() }

    func start(store: LocalCaptureStore) async {
        guard !isStarting, !isRecording, transcribingID == nil else { return }
        stopPlayback()
        cancelTranscription()
        let token = UUID()
        generation = token
        isStarting = true
        defer { if generation == token { isStarting = false } }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard generation == token else { return }
        guard allowed else {
            notice = "Microphone access denied. Enable it in iOS Settings to record."
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            // Commit metadata BEFORE the recorder writes: a terminated recording stays discoverable.
            let capture = try store.create(kind: .voice, title: "Voice recording", attachments: [Data()])
            let url = try store.attachmentURL(capture, name: capture.attachments[0])
            let recording = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recording.delegate = self
            guard recording.prepareToRecord() else { throw CaptureError.message("Cannot prepare recording.") }
            try LocalCaptureStore.protect(url)
            guard recording.record() else { throw CaptureError.message("Cannot start recording.") }
            recorder = recording
            isRecording = true
        } catch {
            stop()
            notice = "Recording could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        generation = UUID()
        isStarting = false
        recorder?.stop()
        recorder = nil
        isRecording = false
        stopPlayback()
        cancelTranscription()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        if !isRecording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func play(_ capture: LocalCapture, store: LocalCaptureStore) {
        guard !isRecording, !isStarting, transcribingID == nil,
              let name = capture.attachments.first else { return }
        stopPlayback()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let playback = try AVAudioPlayer(contentsOf: store.attachmentURL(capture, name: name))
            playback.delegate = self
            guard playback.play() else { throw CaptureError.message("Recording cannot be played.") }
            player = playback
            playingID = capture.id
        } catch {
            stopPlayback()
            notice = "Playback failed: \(error.localizedDescription). The recording has not been deleted."
        }
    }

    func transcribe(_ capture: LocalCapture, store: LocalCaptureStore) async {
        guard !isRecording, !isStarting, transcribingID == nil,
              let name = capture.attachments.first else { return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
            notice = "Offline transcription is unavailable for this device or language. Recording kept; no server fallback."
            return
        }
        stopPlayback()
        transcribingID = capture.id
        let token = UUID()
        generation = token
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == token else { return }
        guard status == .authorized, recognizer.isAvailable else {
            cancelTranscription()
            notice = "Speech permission or offline recognition is unavailable. Recording kept. Check iOS Settings."
            return
        }
        do {
            let request = SFSpeechURLRecognitionRequest(url: try store.attachmentURL(capture, name: name))
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                let failure = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let text {
                        // Fetch the latest version so recognition never overwrites intervening edits.
                        if var latest = store.captures.first(where: { $0.id == capture.id }) {
                            latest.text += (latest.text.isEmpty ? "" : "\n\n") + text
                            do { try store.save(latest) }
                            catch { self.notice = "Transcript could not be saved: \(error.localizedDescription). Recording kept." }
                        }
                        self.cancelTranscription()
                    } else if let failure {
                        self.cancelTranscription()
                        self.notice = "Offline transcription failed: \(failure). Recording kept."
                    }
                }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.cancelTranscription()
                self.notice = "Offline transcription timed out. Recording kept; retry when ready."
            }
        } catch {
            cancelTranscription()
            notice = "Transcription failed: \(error.localizedDescription). Recording kept."
        }
    }

    func cancelTranscription() {
        generation = UUID()
        recognition?.cancel()
        recognition = nil
        timeout?.cancel()
        timeout = nil
        transcribingID = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.stop()
            if !flag { self.notice = "Recording ended unexpectedly. Available audio has been kept." }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.stop()
            self.notice = "Recording failed. Available audio has been kept; check playback."
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            self.stopPlayback()
        }
    }
}
