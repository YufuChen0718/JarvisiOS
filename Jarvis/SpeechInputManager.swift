@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

/// Streams microphone audio into on-device / server speech recognition and
/// fires an "endpoint" when the user goes quiet for `silenceThreshold` seconds.
/// That silence detection is what turns single-shot dictation into a natural
/// back-and-forth conversation.
@Observable
@MainActor
final class SpeechInputManager {
    private let audioEngine = AVAudioEngine()
    /// AVAudioSession activation may block while iOS negotiates an audio route.
    /// Keep it off MainActor so tapping the microphone never stalls SwiftUI.
    private let audioSessionQueue = DispatchQueue(label: "jarvis.audio.session", qos: .userInitiated)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasAudioTap = false

    private var onPartial: (@MainActor (String) -> Void)?
    private var onEndpoint: (@MainActor (String) -> Void)?
    private var onFailure: (@MainActor (Error) -> Void)?
    private var endpointWork: DispatchWorkItem?
    private var noInputWork: DispatchWorkItem?
    private var didFireEndpoint = false

    /// How long the user must pause before we treat a sentence as finished.
    var silenceThreshold: TimeInterval = 1.1

    private(set) var transcript = ""
    private(set) var isListening = false

    /// Begin one turn of continuous listening. Resolves the spoken sentence
    /// through `onEndpoint` once the user pauses.
    func startTurn(onPartial: @escaping @MainActor (String) -> Void,
                   onEndpoint: @escaping @MainActor (String) -> Void,
                   onFailure: @escaping @MainActor (Error) -> Void) async throws {
        guard !isListening else { return }
        guard await requestAuthorization() else { throw SpeechError.permissionDenied }
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        #if DEBUG
        print("[JARVIS][Speech] authorized and recognizer available")
        #endif

        self.onPartial = onPartial
        self.onEndpoint = onEndpoint
        self.onFailure = onFailure
        didFireEndpoint = false
        transcript = ""

        try await configureAudioSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.noInputWork?.cancel() // heard something; stop the watchdog
                    }
                    self.onPartial?(self.transcript)
                    self.scheduleEndpoint()
                }
                if let error, self.isListening, !self.didFireEndpoint {
                    self.finishWithFailure(SpeechError.recognitionFailed(error.localizedDescription))
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            cancel()
            throw SpeechError.noAudioInput
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasAudioTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            scheduleNoInputWatchdog()
            #if DEBUG
            print("[JARVIS][Speech] audio engine started")
            #endif
        } catch {
            cancel()
            throw error
        }
    }

    /// Stop listening immediately without firing an endpoint (e.g. user tapped stop).
    func cancel() {
        endpointWork?.cancel()
        endpointWork = nil
        noInputWork?.cancel()
        noInputWork = nil
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        onFailure = nil
        transcript = ""
    }

    private func scheduleEndpoint() {
        endpointWork?.cancel()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !didFireEndpoint else { return }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening, !self.didFireEndpoint else { return }
                self.didFireEndpoint = true
                let sentence = self.transcript
                self.stopAudioCapture()
                self.recognitionRequest?.endAudio()
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
                self.recognitionRequest = nil
                self.onEndpoint?(sentence)
            }
        }
        endpointWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceThreshold, execute: work)
    }

    /// If we never hear a single word within a few seconds, the microphone is
    /// almost certainly muted or permission-blocked — surface that instead of
    /// silently sitting in "listening" forever.
    private func scheduleNoInputWatchdog() {
        noInputWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening, !self.didFireEndpoint,
                      self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.finishWithFailure(SpeechError.noSpeechHeard)
            }
        }
        noInputWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func stopAudioCapture() {
        noInputWork?.cancel()
        noInputWork = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        isListening = false
        deactivateAudioSession()
    }

    private func configureAudioSession() async throws {
        let queue = audioSessionQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playAndRecord,
                                            mode: .measurement,
                                            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true, options: [])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SpeechError.audioSession(error.localizedDescription))
                }
            }
        }
    }

    private func deactivateAudioSession() {
        let queue = audioSessionQueue
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func finishWithFailure(_ error: Error) {
        endpointWork?.cancel()
        endpointWork = nil
        stopAudioCapture()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        let callback = onFailure
        onFailure = nil
        callback?(error)
    }

    private func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        return speechStatus == .authorized && microphoneAllowed
    }

    enum SpeechError: LocalizedError {
        case permissionDenied
        case unavailable
        case noAudioInput
        case noSpeechHeard
        case audioSession(String)
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "请在系统设置中允许麦克风和语音识别，才能进行语音对话。"
            case .unavailable: "当前设备暂时无法使用语音识别，请稍后再试。"
            case .noAudioInput: "没有检测到可用的麦克风输入。请断开异常的蓝牙音频设备后重试。"
            case .noSpeechHeard: "没听到声音。请到「设置 › JARVIS」确认已允许麦克风和语音识别，并确保手机没有静音麦克风，然后重试。"
            case .audioSession(let detail): "无法启动麦克风：\(detail)"
            case .recognitionFailed(let detail): "语音识别中断：\(detail)"
            }
        }
    }
}
