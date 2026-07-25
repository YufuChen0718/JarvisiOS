import Foundation
import Observation
import UIKit

/// Orchestrates the full hands-free conversation:
///
///   聆听 → (静音判定) → 抓取当前画面 → 流式回答 → 语音播报 → 自动回到聆听
///
/// Each turn snapshots the live camera frame, so answers are grounded in what
/// the phone is looking at right now. Multi-turn context is carried forward so
/// follow-up questions ("那它旁边那个呢？") resolve correctly.
@Observable
@MainActor
final class AssistantSession {
    let camera = CameraManager()
    let speechInput = SpeechInputManager()
    let speechOutput = SpeechOutputManager()
    let configuration: AppConfiguration

    private var service: any AssistantService
    private var responseTask: Task<Void, Never>?

    private(set) var phase: AssistantPhase = .idle
    private(set) var isConversationActive = false
    private(set) var liveTranscript = ""
    private(set) var answerText = ""
    private(set) var currentQuestion = ""
    private(set) var history: [ConversationTurn] = []
    private(set) var lastImage: UIImage?

    var errorMessage: String?

    init(configuration: AppConfiguration = .current) {
        self.configuration = configuration
        self.service = Self.makeService(configuration)
        speechOutput.onFinish = { [weak self] in
            self?.resumeListeningIfActive()
        }
    }

    /// Pick the answer backend. Direct-to-OpenAI (Keychain key) wins so the app
    /// works anywhere with no computer; otherwise fall back to a LAN backend or
    /// the offline demo.
    private static func makeService(_ config: AppConfiguration) -> any AssistantService {
        if let key = config.effectiveOpenAIKey {
            return DirectOpenAIService(apiKey: key,
                                       model: config.openAIModel,
                                       enableWebSearch: config.webSearchEnabled)
        }
        if config.usesDemoService {
            return DemoAssistantService()
        }
        return BackendAssistantService(baseURL: config.backendURL!, token: config.backendToken)
    }

    /// True when the app can answer on its own (direct OpenAI key present).
    var isDirectMode: Bool { configuration.effectiveOpenAIKey != nil }
    var apiKeyIsConfigured: Bool { configuration.effectiveOpenAIKey != nil }

    /// Save (or clear) the in-app OpenAI key and rebuild the answering service.
    func updateAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.apiKey = (trimmed?.isEmpty == false) ? trimmed : nil
        stopConversation()
        service = Self.makeService(configuration)
        errorMessage = nil
    }

    // MARK: - Conversation control

    /// Prepare the live preview independently from voice conversation.
    /// The camera should be useful as soon as the app is opened.
    func enterForeground() {
        camera.start()
        #if DEBUG
        Task { await probeBackendForDiagnostics() }
        #endif
    }

    func enterBackground() {
        stopConversation()
        camera.stop()
    }

    /// Big mic button entry point. Starts the camera and the listening loop.
    func toggleConversation() {
        if isConversationActive {
            stopConversation()
        } else {
            startConversation()
        }
    }

    func startConversation() {
        errorMessage = nil
        isConversationActive = true
        if camera.state != .running { camera.start() }
        beginListening()
    }

    func stopConversation() {
        isConversationActive = false
        responseTask?.cancel()
        responseTask = nil
        speechInput.cancel()
        speechOutput.stop()
        liveTranscript = ""
        phase = history.isEmpty ? .idle : .completed
    }

    private func beginListening() {
        guard isConversationActive else { return }
        phase = .listening
        liveTranscript = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.speechInput.startTurn(
                    onPartial: { [weak self] text in
                        self?.liveTranscript = text
                    },
                    onEndpoint: { [weak self] sentence in
                        self?.handleSpokenQuestion(sentence)
                    },
                    onFailure: { [weak self] error in
                        guard let self else { return }
                        self.isConversationActive = false
                        self.present(error)
                    }
                )
            } catch {
                self.present(error)
                self.isConversationActive = false
            }
        }
    }

    private func resumeListeningIfActive() {
        guard isConversationActive else { return }
        beginListening()
    }

    private func handleSpokenQuestion(_ sentence: String) {
        let question = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConversationActive, !question.isEmpty else {
            resumeListeningIfActive()
            return
        }
        answer(question: question)
    }

    // MARK: - Typed questions (fallback / simulator)

    func submitTypedQuestion(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        speechInput.cancel()
        answer(question: question)
    }

    /// Lets the simulator (no camera) still exercise the loop.
    func useImportedImage(_ data: Data) {
        lastImage = UIImage(data: data)
        importedImageData = data
    }

    private var importedImageData: Data?

    // MARK: - Answering

    private func answer(question: String) {
        speechOutput.stop()
        responseTask?.cancel()

        let imageData = camera.captureJPEG() ?? importedImageData ?? Self.placeholderJPEG
        if let image = UIImage(data: imageData) { lastImage = image }

        currentQuestion = question
        answerText = ""
        liveTranscript = ""
        errorMessage = nil
        phase = .thinking

        let request = AssistantRequest(
            question: question,
            imageData: imageData,
            conversationSummary: rollingSummary,
            clientID: clientID
        )

        responseTask = Task { [weak self, service = self.service] in
            do {
                for try await delta in service.streamAnswer(for: request) {
                    try Task.checkCancellation()
                    guard let self else { return }
                    if self.phase == .thinking { self.phase = .answering }
                    self.answerText += delta
                }
                guard let self, !Task.isCancelled else { return }
                self.finishAnswer(question: question)
            } catch is CancellationError {
                // Deliberate interruption; state handled by caller.
            } catch {
                guard let self else { return }
                // Stop the loop rather than retry-spamming the same failing request.
                self.isConversationActive = false
                self.speechInput.cancel()
                self.present(error)
            }
        }
    }

    private func finishAnswer(question: String) {
        history.append(ConversationTurn(question: question, answer: answerText))
        if history.count > 8 { history.removeFirst(history.count - 8) }

        if answerText.isEmpty {
            phase = .completed
            resumeListeningIfActive()
        } else {
            phase = .speaking
            speechOutput.speak(answerText) // onFinish → resumeListeningIfActive()
        }
    }

    func stopSpeaking() {
        speechOutput.stop()
        phase = .completed
        resumeListeningIfActive()
    }

    func clearHistory() {
        stopConversation()
        history.removeAll()
        answerText = ""
        currentQuestion = ""
        lastImage = nil
        phase = .idle
    }

    func clearError() { errorMessage = nil }

    // MARK: - Helpers

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        phase = .failed
    }

    #if DEBUG
    private func probeBackendForDiagnostics() async {
        guard !configuration.usesDemoService,
              let baseURL = configuration.backendURL else {
            print("[JARVIS][Backend] demo mode")
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[JARVIS][Backend] health status=\(status) url=\(request.url?.absoluteString ?? "unknown")")
        } catch {
            print("[JARVIS][Backend] health failed url=\(request.url?.absoluteString ?? "unknown") error=\(error.localizedDescription)")
        }
    }
    #endif

    /// Last few turns, so the model can resolve follow-up references.
    private var rollingSummary: String {
        guard !history.isEmpty else { return "" }
        return history.suffix(3).map { turn in
            "问：\(turn.question)\n答：\(turn.answer.prefix(300))"
        }.joined(separator: "\n\n")
    }

    private var clientID: String {
        let key = "jarvis.client-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    /// Tiny black JPEG used only in demo / simulator so a request always has a
    /// valid (unused) image field.
    static let placeholderJPEG: Data = {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.6) ?? Data(repeating: 0, count: 64)
    }()
}
