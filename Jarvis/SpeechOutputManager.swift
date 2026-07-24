import AVFoundation
import Observation

/// Speaks answers aloud and reports when it naturally finishes, so the
/// conversation loop knows when to start listening for the next question.
@Observable
@MainActor
final class SpeechOutputManager: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    /// Called only when speech finishes on its own (not when interrupted).
    var onFinish: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let plainText = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")

        let utterance = AVSpeechUtterance(string: plainText)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// Stop speaking because of a deliberate interruption. Does NOT trigger `onFinish`.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}
