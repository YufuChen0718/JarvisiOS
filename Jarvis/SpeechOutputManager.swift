import AVFoundation
import Observation

enum SpeechEngine: String { case system, elevenLabs, qwen, voicebox }

/// Speaks answers aloud via one of three engines:
///   • system     — Apple AVSpeechSynthesizer (incl. on-device Personal Voice)
///   • elevenLabs — ElevenLabs cloud TTS (cloned voice)
///   • qwen       — Alibaba DashScope Qwen3-TTS (preset or cloned voice)
/// Cloud calls fall back to the system voice on failure so you always hear the answer.
@Observable
@MainActor
final class SpeechOutputManager: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private(set) var isSpeaking = false
    private(set) var isRecording = false
    private(set) var isCloning = false
    private(set) var recordedURL: URL?
    private(set) var cloneStatus: String?
    /// Last speak/preview error, surfaced in the voice sheet for debugging.
    private(set) var speechError: String?
    private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    private var suppressFinishCallback = false

    var onFinish: (@MainActor () -> Void)?

    // MARK: - Persisted settings

    var engine: SpeechEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "jarvis.tts-engine") }
    }
    var selectedVoiceID: String? { didSet { persist(selectedVoiceID, "jarvis.voice-id") } }

    // ElevenLabs
    var elevenVoiceID: String? { didSet { persist(elevenVoiceID, "jarvis.eleven-voice-id") } }
    var elevenModel: String { didSet { UserDefaults.standard.set(elevenModel, forKey: "jarvis.eleven-model") } }

    // Qwen3-TTS (DashScope)
    var qwenVoice: String { didSet { UserDefaults.standard.set(qwenVoice, forKey: "jarvis.qwen-voice") } }
    var qwenModel: String { didSet { UserDefaults.standard.set(qwenModel, forKey: "jarvis.qwen-model") } }
    var qwenRegionIntl: Bool { didSet { UserDefaults.standard.set(qwenRegionIntl, forKey: "jarvis.qwen-intl") } }

    // Voicebox / custom local TTS endpoint
    var voiceboxURL: String { didSet { UserDefaults.standard.set(voiceboxURL, forKey: "jarvis.voicebox-url") } }
    var voiceboxProfile: String { didSet { UserDefaults.standard.set(voiceboxProfile, forKey: "jarvis.voicebox-profile") } }

    override init() {
        let d = UserDefaults.standard
        engine = SpeechEngine(rawValue: d.string(forKey: "jarvis.tts-engine") ?? "") ?? .system
        elevenModel = d.string(forKey: "jarvis.eleven-model") ?? "eleven_multilingual_v2"
        qwenVoice = d.string(forKey: "jarvis.qwen-voice") ?? "Cherry"
        qwenModel = d.string(forKey: "jarvis.qwen-model") ?? "qwen3-tts-flash"
        qwenRegionIntl = d.object(forKey: "jarvis.qwen-intl") == nil ? true : d.bool(forKey: "jarvis.qwen-intl")
        voiceboxURL = d.string(forKey: "jarvis.voicebox-url") ?? ""
        voiceboxProfile = d.string(forKey: "jarvis.voicebox-profile") ?? ""
        super.init()
        selectedVoiceID = d.string(forKey: "jarvis.voice-id")
        elevenVoiceID = d.string(forKey: "jarvis.eleven-voice-id")
        synthesizer.delegate = self
        loadVoices()
    }

    var elevenConfigured: Bool { KeychainStore.elevenLabsKey != nil && (elevenVoiceID?.isEmpty == false) }
    var qwenConfigured: Bool { KeychainStore.dashScopeKey != nil && !qwenVoice.isEmpty }
    var voiceboxConfigured: Bool { !voiceboxURL.isEmpty }

    // MARK: - System voices

    var hasPersonalVoice: Bool { availableVoices.contains { $0.voiceTraits.contains(.isPersonalVoice) } }

    func loadVoices() {
        availableVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.voiceTraits.contains(.isPersonalVoice) }
            .sorted {
                let l = $0.voiceTraits.contains(.isPersonalVoice)
                let r = $1.voiceTraits.contains(.isPersonalVoice)
                if l != r { return l }
                return $0.name < $1.name
            }
    }

    func requestPersonalVoice() async {
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { c.resume(returning: $0 == .authorized) }
        }
        loadVoices()
    }

    // MARK: - Settings mutators

    func applyElevenLabs(key: String?, voiceID: String?) {
        if let k = trimmed(key) { KeychainStore.elevenLabsKey = k }
        if let v = trimmed(voiceID) { elevenVoiceID = v }
        engine = elevenConfigured ? .elevenLabs : .system
    }

    func applyQwen(key: String?, voice: String?, model: String?, intl: Bool) {
        if let k = trimmed(key) { KeychainStore.dashScopeKey = k }
        if let v = trimmed(voice) { qwenVoice = v }
        if let m = trimmed(model) { qwenModel = m }
        qwenRegionIntl = intl
        engine = qwenConfigured ? .qwen : .system
    }

    func applyVoicebox(url: String?, profile: String?) {
        voiceboxURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? voiceboxURL
        voiceboxProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? voiceboxProfile
        engine = voiceboxConfigured ? .voicebox : .system
    }

    func useSystemVoice(_ voiceID: String) {
        selectedVoiceID = voiceID
        engine = .system
    }

    // MARK: - Voice cloning (record -> enroll)

    func startRecording() {
        stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-clone.m4a")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            recordedURL = nil
            isRecording = true
            cloneStatus = "正在录音…请用正常语速说 10–20 秒"
        } catch {
            cloneStatus = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recorder?.stop()
        recordedURL = recorder?.url
        recorder = nil
        isRecording = false
        if recordedURL != nil { cloneStatus = "录音完成，点“开始克隆”。" }
    }

    func cloneRecordedVoice() async {
        guard let url = recordedURL, let data = try? Data(contentsOf: url) else {
            cloneStatus = "请先录一段音频。"; return
        }
        await cloneFromData(data, mime: "audio/mp4")
    }

    /// Clone from any provided audio bytes (e.g. an imported high-quality file).
    func cloneFromData(_ data: Data, mime: String) async {
        guard !data.isEmpty, data.count < 10 * 1024 * 1024 else {
            cloneStatus = "音频为空或超过 10MB，请换一段 10–20 秒的干净音频。"; return
        }
        guard let key = KeychainStore.dashScopeKey else {
            cloneStatus = "请先在上面填好 DashScope API Key。"; return
        }
        isCloning = true
        cloneStatus = "正在克隆声音…（约十几秒）"
        do {
            let name = "jarvis" + String(Int.random(in: 100_000...999_999))
            let voice = try await QwenTTS.enroll(audioData: data, mime: mime, name: name,
                                                 targetModel: "qwen3-tts-vc-2026-01-22", language: "zh",
                                                 apiKey: key, intl: qwenRegionIntl)
            qwenVoice = voice
            qwenModel = "qwen3-tts-vc-2026-01-22"
            qwenRegionIntl = true
            engine = .qwen
            cloneStatus = "克隆成功！已启用你的声音，正在试听。"
            previewCurrent()
        } catch {
            cloneStatus = "克隆失败：\(error.localizedDescription)"
        }
        isCloning = false
    }

    // MARK: - Speak

    func speak(_ text: String) {
        speechError = nil
        let plain = clean(text)
        switch engine {
        case .elevenLabs where elevenConfigured: Task { await speakEleven(plain, isPreview: false) }
        case .qwen where qwenConfigured: Task { await speakQwen(plain, isPreview: false) }
        case .voicebox where voiceboxConfigured: Task { await speakVoicebox(plain, isPreview: false) }
        default: speakSystem(plain, isPreview: false)
        }
    }

    func previewSystem(voiceID: String) { speakSystem(sampleText, isPreview: true, voiceID: voiceID) }

    func previewCurrent() {
        speechError = nil
        switch engine {
        case .elevenLabs where elevenConfigured: Task { await speakEleven(sampleText, isPreview: true) }
        case .qwen where qwenConfigured: Task { await speakQwen(sampleText, isPreview: true) }
        case .voicebox where voiceboxConfigured: Task { await speakVoicebox(sampleText, isPreview: true) }
        default: speakSystem(sampleText, isPreview: true)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    private func speakSystem(_ text: String, isPreview: Bool, voiceID: String? = nil) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let id = voiceID ?? selectedVoiceID
        utterance.voice = (id.flatMap(AVSpeechSynthesisVoice.init(identifier:))) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        suppressFinishCallback = isPreview
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    private func speakEleven(_ text: String, isPreview: Bool) async {
        guard let key = KeychainStore.elevenLabsKey, let voice = elevenVoiceID else {
            speakSystem(text, isPreview: isPreview); return
        }
        do {
            let data = try await ElevenLabsTTS.synthesize(text: text, voiceID: voice, modelID: elevenModel, apiKey: key)
            try playAudio(data, isPreview: isPreview)
        } catch {
            speechError = "ElevenLabs：\(error.localizedDescription)"
            if !isPreview { speakSystem(text, isPreview: false) }
        }
    }

    private func speakQwen(_ text: String, isPreview: Bool) async {
        guard let key = KeychainStore.dashScopeKey else { speakSystem(text, isPreview: isPreview); return }
        do {
            let data = try await QwenTTS.synthesize(text: text, voice: qwenVoice, model: qwenModel,
                                                    apiKey: key, intl: qwenRegionIntl)
            try playAudio(data, isPreview: isPreview)
        } catch {
            speechError = "Qwen：\(error.localizedDescription)"
            if !isPreview { speakSystem(text, isPreview: false) }
        }
    }

    private func speakVoicebox(_ text: String, isPreview: Bool) async {
        guard !voiceboxURL.isEmpty else { speakSystem(text, isPreview: isPreview); return }
        do {
            let data = try await VoiceboxTTS.synthesize(text: text, baseURL: voiceboxURL, profile: voiceboxProfile)
            try playAudio(data, isPreview: isPreview)
        } catch {
            speechError = "Voicebox：\(error.localizedDescription)"
            if !isPreview { speakSystem(text, isPreview: false) }
        }
    }

    private func playAudio(_ data: Data, isPreview: Bool) throws {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        audioPlayer = player
        suppressFinishCallback = isPreview
        isSpeaking = true
        player.play()
    }

    // MARK: - Delegates

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishSpeaking() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishSpeaking() }
    }

    private func finishSpeaking() {
        isSpeaking = false
        if suppressFinishCallback { suppressFinishCallback = false; return }
        onFinish?()
    }

    // MARK: - Helpers

    private let sampleText = "你好，我是 JARVIS，这是我说话的声音。"
    private func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
    private func trimmed(_ v: String?) -> String? {
        let t = v?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }
    private func persist(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - ElevenLabs TTS client

enum ElevenLabsTTS {
    struct VoiceInfo: Identifiable { let id: String; let name: String }

    static func synthesize(text: String, voiceID: String, modelID: String, apiKey: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ElevenLabs", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "ElevenLabs 合成失败（HTTP \(status)）"])
        }
        return data
    }

    static func listVoices(apiKey: String) async throws -> [VoiceInfo] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ElevenLabs", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "无法获取声音列表（HTTP \(status)）"])
        }
        struct Resp: Decodable { struct V: Decodable { let voice_id: String; let name: String? }; let voices: [V] }
        return try JSONDecoder().decode(Resp.self, from: data).voices.map { VoiceInfo(id: $0.voice_id, name: $0.name ?? $0.voice_id) }
    }
}

// MARK: - Qwen3-TTS (Alibaba DashScope) client

enum QwenTTS {
    /// Non-streaming synthesis: returns the completed audio (WAV) bytes.
    static func synthesize(text: String, voice: String, model: String, apiKey: String, intl: Bool) async throws -> Data {
        let base = intl ? "https://dashscope-intl.aliyuncs.com" : "https://dashscope.aliyuncs.com"
        var req = URLRequest(url: URL(string: base + "/api/v1/services/aigc/multimodal-generation/generation")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [
                "text": text,
                "voice": voice,
                // Tell the multilingual model the text language, otherwise it
                // mispronounces and sounds like gibberish.
                "language_type": "Chinese",
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = (try? JSONDecoder().decode(ErrorResp.self, from: data))?.message
            throw NSError(domain: "QwenTTS", code: status,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? "Qwen3-TTS 合成失败（HTTP \(status)）"])
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let urlString = decoded.output?.audio?.url, let audioURL = URL(string: urlString) else {
            throw NSError(domain: "QwenTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Qwen3-TTS 未返回音频"])
        }
        let (audioData, audioResp) = try await URLSession.shared.data(from: audioURL)
        guard let ah = audioResp as? HTTPURLResponse, (200..<300).contains(ah.statusCode) else {
            throw NSError(domain: "QwenTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "音频下载失败"])
        }
        return audioData
    }

    /// One-time voice cloning: upload a short sample, get back a voice name.
    static func enroll(audioData: Data, mime: String, name: String, targetModel: String,
                       language: String, apiKey: String, intl: Bool) async throws -> String {
        let base = intl ? "https://dashscope-intl.aliyuncs.com" : "https://dashscope.aliyuncs.com"
        var req = URLRequest(url: URL(string: base + "/api/v1/services/audio/tts/customization")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let dataURI = "data:\(mime);base64,\(audioData.base64EncodedString())"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "qwen-voice-enrollment",
            "input": [
                "action": "create",
                "target_model": targetModel,
                "preferred_name": name,
                "language": language,
                "audio": ["data": dataURI],
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = (try? JSONDecoder().decode(ErrorResp.self, from: data))?.message
            throw NSError(domain: "QwenTTS", code: status,
                          userInfo: [NSLocalizedDescriptionKey: msg ?? "克隆失败（HTTP \(status)）"])
        }
        let decoded = try JSONDecoder().decode(EnrollResp.self, from: data)
        guard let voice = decoded.output?.voice, !voice.isEmpty else {
            throw NSError(domain: "QwenTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "未返回克隆声音"])
        }
        return voice
    }

    private struct EnrollResp: Decodable {
        struct Output: Decodable { let voice: String? }
        let output: Output?
        let message: String?
    }

    private struct Resp: Decodable {
        struct Output: Decodable { struct Audio: Decodable { let url: String? }; let audio: Audio? }
        let output: Output?
        let message: String?
    }
    private struct ErrorResp: Decodable { let message: String? }
}

// MARK: - Voicebox / custom local TTS client

enum VoiceboxTTS {
    /// POST {text, profile_id, language} to a local endpoint and expect audio bytes.
    static func synthesize(text: String, baseURL: String, profile: String) async throws -> Data {
        guard let url = URL(string: baseURL) else {
            throw NSError(domain: "Voicebox", code: -1, userInfo: [NSLocalizedDescriptionKey: "地址无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/*, application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["text": text, "language": "zh"]
        if !profile.isEmpty { body["profile_id"] = profile; body["profile"] = profile }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail: String? = {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return String(data: data, encoding: .utf8)
                }
                return (object["detail"] as? String) ?? (object["error"] as? String)
            }()
            let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = normalizedDetail.isEmpty ? "" : "：\(normalizedDetail)"
            throw NSError(domain: "Voicebox", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Voicebox 请求失败（HTTP \(status)）\(suffix)"])
        }
        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ctype.contains("audio") || looksLikeAudio(data) { return data }
        // Some endpoints return JSON with a URL to the audio.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlStr = (obj["url"] as? String) ?? ((obj["output"] as? [String: Any])?["url"] as? String),
           let audioURL = URL(string: urlStr) {
            let (audioData, aResp) = try await URLSession.shared.data(from: audioURL)
            if let ah = aResp as? HTTPURLResponse, (200..<300).contains(ah.statusCode) { return audioData }
        }
        throw NSError(domain: "Voicebox", code: -1, userInfo: [NSLocalizedDescriptionKey:
            "返回的不是音频（可能是异步任务）。请用能同步返回音频字节的接口地址。"])
    }

    private static func looksLikeAudio(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        if b.count >= 4, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return true } // RIFF/WAV
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return true }               // ID3/MP3
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return true }                     // MPEG audio
        if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true }  // ftyp (m4a/mp4)
        return false
    }
}
