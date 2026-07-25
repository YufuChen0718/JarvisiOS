import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Aether Intelligence" JARVIS HUD:
///   full-bleed camera · glass status hub · glass answer card · arc-reactor mic.
struct ConversationView: View {
    @Environment(AssistantSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    @State private var photoItem: PhotosPickerItem?
    @State private var showTypeField = false
    @State private var typedText = ""
    @State private var showKeySheet = false
    @State private var showVoiceSheet = false
    @State private var elevenKeyInput = ""
    @State private var elevenVoiceIdInput = ""
    @State private var elevenVoices: [ElevenLabsTTS.VoiceInfo] = []
    @State private var elevenError: String?
    @State private var qwenKeyInput = ""
    @State private var qwenVoiceInput = ""
    @State private var qwenModelInput = ""
    @State private var qwenIntl = true
    @State private var showAudioImporter = false
    @State private var voiceboxUrlInput = ""
    @State private var voiceboxProfileInput = ""
    @State private var keyInput = ""
    @State private var modelInput = ""
    @State private var deepSeekKeyInput = ""
    @State private var deepSeekModelInput = ""

    var body: some View {
        ZStack {
            cameraBackground
                .ignoresSafeArea()

            JarvisDesign.hudVignette
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topHUD
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                Spacer(minLength: 12)

                if !showsCard {
                    idleHint
                        .transition(.opacity)
                    Spacer(minLength: 12)
                }

                if showsCard {
                    conversationCard
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                micDock
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showsCard)
        .task { session.enterForeground() }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: session.enterForeground()
            case .background: session.enterBackground()
            default: break
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    session.useImportedImage(data)
                }
                photoItem = nil
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.clearError() } }
            )
        ) {
            if shouldOfferSettings {
                Button("打开设置") { openAppSettings() }
            }
            Button("知道了", role: .cancel) { session.clearError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .sheet(isPresented: $showKeySheet) { apiKeySheet }
        .sheet(isPresented: $showVoiceSheet) { voiceSheet }
    }

    // MARK: - Camera background

    @ViewBuilder
    private var cameraBackground: some View {
        switch session.camera.state {
        case .running:
            CameraPreview(displayLayer: session.camera.displayLayer)
        default:
            ZStack {
                JarvisDesign.background
                if let image = session.lastImage {
                    Image(uiImage: image).resizable().scaledToFill().opacity(0.4)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 46, weight: .thin))
                            .foregroundStyle(JarvisDesign.primary.opacity(0.7))
                        Text(cameraPlaceholder)
                            .font(.callout)
                            .foregroundStyle(JarvisDesign.onSurface.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                        cameraRecoveryAction
                    }
                }
            }
        }
    }

    private var cameraPlaceholder: String {
        switch session.camera.state {
        case .denied, .failed: session.camera.diagnostic
        case .configuring: "正在准备摄像头…"
        default: "正在启动实时摄像头…"
        }
    }

    @ViewBuilder
    private var cameraRecoveryAction: some View {
        switch session.camera.state {
        case .denied:
            Button("打开相机权限") { openAppSettings() }
                .buttonStyle(.borderedProminent).tint(JarvisDesign.primaryDeep)
        case .failed:
            Button("重试摄像头") { session.camera.start() }
                .buttonStyle(.bordered).tint(JarvisDesign.primary)
        default:
            EmptyView()
        }
    }

    // MARK: - Top HUD (logo · status hub · menu)

    private var topHUD: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                LogoMark()
                Spacer(minLength: 6)
                statusHub
                Spacer(minLength: 6)
                menuButton
            }
            #if DEBUG
            Text("frames \(session.camera.previewFrameCount) · \(session.configuration.modeLabel)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(JarvisDesign.onSurface.opacity(0.28))
            #endif
        }
    }

    private var statusHub: some View {
        HStack(spacing: 14) {
            IntelligenceChip(title: "CAM", value: camValue, color: camColor,
                             showsDot: true, breathing: session.camera.state == .running)
            Rectangle()
                .fill(LinearGradient(colors: [.clear, JarvisDesign.primaryDeep.opacity(0.5), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: 16)
            IntelligenceChip(title: "AI", value: aiValue, color: aiColor,
                             systemIcon: aiIcon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glass(cornerRadius: 999, active: session.phase == .thinking || session.phase == .answering)
    }

    private var menuButton: some View {
        Menu {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("导入图片", systemImage: "photo")
            }
            Button { showTypeField.toggle() } label: {
                Label("输入文字提问", systemImage: "keyboard")
            }
            Button {
                session.speechOutput.loadVoices()
                elevenKeyInput = ""
                elevenVoiceIdInput = session.speechOutput.elevenVoiceID ?? ""
                elevenVoices = []
                elevenError = nil
                qwenKeyInput = ""
                qwenVoiceInput = session.speechOutput.qwenVoice
                qwenModelInput = session.speechOutput.qwenModel
                qwenIntl = session.speechOutput.qwenRegionIntl
                voiceboxUrlInput = session.speechOutput.voiceboxURL
                voiceboxProfileInput = session.speechOutput.voiceboxProfile
                showVoiceSheet = true
            } label: {
                Label("语音", systemImage: "waveform")
            }
            Button {
                keyInput = ""
                deepSeekKeyInput = ""
                modelInput = session.currentModel
                deepSeekModelInput = session.currentDeepSeekModel
                showKeySheet = true
            } label: {
                Label("模型与 API Key", systemImage: "key")
            }
            Button(role: .destructive) { session.clearHistory() } label: {
                Label("清空对话", systemImage: "trash")
            }
            Divider()
            Text(session.configuration.modeLabel)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(JarvisDesign.onSurface)
                .frame(width: 40, height: 40)
                .glass(cornerRadius: 999)
        }
    }

    private var idleHint: some View {
        VStack(spacing: 8) {
            Text("JARVIS")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(6)
                .foregroundStyle(JarvisDesign.onSurface.opacity(0.85))
            Text("点亮反应堆，对准物体开口提问")
                .font(.footnote)
                .foregroundStyle(JarvisDesign.onSurface.opacity(0.5))
        }
    }

    // MARK: - Conversation card (glass)

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(pastTurns) { turn in
                                turnView(question: turn.question, answer: turn.answer, dim: true)
                            }
                            if !session.currentQuestion.isEmpty {
                                turnView(question: session.currentQuestion,
                                         answer: session.answerText,
                                         dim: false,
                                         streaming: session.phase == .answering)
                                    .id("current")
                            }
                            if session.phase == .thinking { thinkingRow.id("current") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: session.answerText) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("current", anchor: .bottom) }
                    }
                }
            }

            if session.phase == .listening { listeningBar }
            if showTypeField { typeBar }
        }
        .glass(cornerRadius: 24, active: session.phase != .idle && session.phase != .completed)
    }

    private var hasConversation: Bool {
        !session.currentQuestion.isEmpty || !session.history.isEmpty
    }

    private var showsCard: Bool {
        hasConversation
            || session.phase == .listening
            || session.phase == .thinking
            || showTypeField
    }

    private var pastTurns: [ConversationTurn] {
        guard let last = session.history.last else { return [] }
        if !session.currentQuestion.isEmpty && last.question == session.currentQuestion {
            return Array(session.history.dropLast())
        }
        return session.history
    }

    private func turnView(question: String, answer: String, dim: Bool, streaming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(JarvisDesign.onSurface.opacity(0.5))
                    .padding(.top, 2)
                Text(question)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(JarvisDesign.onSurface.opacity(dim ? 0.5 : 0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !answer.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(JarvisDesign.primary.opacity(dim ? 0.5 : 1))
                        .padding(.top, 3)
                    answerText(answer, dim: dim, streaming: streaming)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerText(_ text: String, dim: Bool, streaming: Bool) -> some View {
        let rendered: Text = (try? AttributedString(markdown: text)).map(Text.init) ?? Text(text)
        return rendered
            .font(.system(.body, design: .rounded))
            .foregroundStyle(JarvisDesign.onSurface.opacity(dim ? 0.6 : 0.98))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                if streaming {
                    Circle().fill(JarvisDesign.primary).frame(width: 6, height: 6).offset(x: 10, y: -4)
                }
            }
    }

    private var thinkingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(JarvisDesign.primary)
            Text("正在看画面并核对信息…")
                .font(.callout)
                .foregroundStyle(JarvisDesign.onSurface.opacity(0.7))
        }
    }

    private var listeningBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.callout)
                .foregroundStyle(JarvisDesign.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(session.liveTranscript.isEmpty ? "请开口说话…" : session.liveTranscript)
                .font(.callout)
                .foregroundStyle(JarvisDesign.onSurface.opacity(session.liveTranscript.isEmpty ? 0.5 : 0.95))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var typeBar: some View {
        HStack(spacing: 10) {
            TextField("输入问题…", text: $typedText)
                .textFieldStyle(.plain)
                .foregroundStyle(JarvisDesign.onSurface)
                .tint(JarvisDesign.primary)
                .submitLabel(.send)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(typedText.isEmpty ? JarvisDesign.onSurface.opacity(0.3) : JarvisDesign.primary)
            }
            .disabled(typedText.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().opacity(0.15) }
    }

    private func sendTyped() {
        let text = typedText
        typedText = ""
        session.submitTypedQuestion(text)
    }

    // MARK: - Arc-reactor mic

    private var micDock: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                ZStack {
                    Circle()
                        .fill(orbColor)
                        .frame(width: 78, height: 78)
                        .blur(radius: 26)
                        .opacity(0.55)

                    PulseRing(color: ringColor, active: orbActive, delay: 0)
                        .frame(width: 78, height: 78)
                    PulseRing(color: ringColor, active: orbActive, delay: 1.1)
                        .frame(width: 78, height: 78)

                    Circle()
                        .fill(RadialGradient(
                            colors: [JarvisDesign.coreHighlight, JarvisDesign.secondary, JarvisDesign.secondaryDeep],
                            center: .init(x: 0.4, y: 0.35), startRadius: 2, endRadius: 46))
                        .frame(width: 76, height: 76)
                        .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                        .shadow(color: JarvisDesign.secondary.opacity(0.8), radius: 22)

                    ReactorGlyph()
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(session.phase == .thinking ? 360 : 0))
                        .animation(session.phase == .thinking
                                   ? .linear(duration: 8).repeatForever(autoreverses: false)
                                   : .default,
                                   value: session.phase == .thinking)

                    if session.phase == .answering || session.phase == .speaking {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color(hex: 0x083140))
                    }
                }
                .frame(width: 132, height: 132)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(dockLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(JarvisDesign.onSurface.opacity(0.6))
        }
    }

    private func primaryAction() {
        switch session.phase {
        case .speaking, .answering: session.stopSpeaking()
        default: session.toggleConversation()
        }
    }

    private var orbActive: Bool {
        [.listening, .thinking, .answering, .speaking].contains(session.phase)
    }

    private var orbColor: Color {
        switch session.phase {
        case .thinking, .answering, .speaking: JarvisDesign.primary
        default: JarvisDesign.secondary
        }
    }

    private var ringColor: Color {
        switch session.phase {
        case .thinking, .answering, .speaking: JarvisDesign.primary
        default: JarvisDesign.secondary
        }
    }

    private var dockLabel: String {
        switch session.phase {
        case .listening: "LISTENING · 说完停顿即可"
        case .thinking: "THINKING…"
        case .answering, .speaking: "点击打断"
        case .failed: "点击重试"
        default: session.isConversationActive ? "点击结束" : "点击开始语音对话"
        }
    }

    // MARK: - Status chip values

    private var camValue: String {
        switch session.camera.state {
        case .running: "ACTIVE"
        case .configuring: "BOOT"
        case .denied: "DENIED"
        case .failed: "ERROR"
        case .idle: "IDLE"
        }
    }
    private var camColor: Color {
        switch session.camera.state {
        case .running: JarvisDesign.primary
        case .configuring, .idle: JarvisDesign.warning
        case .denied, .failed: JarvisDesign.danger
        }
    }
    private var aiValue: String {
        switch session.phase {
        case .idle, .completed: "READY"
        case .listening: "LISTENING"
        case .thinking: "THINKING"
        case .answering, .speaking: "SPEAKING"
        case .failed: "ERROR"
        }
    }
    private var aiColor: Color {
        session.phase == .failed ? JarvisDesign.danger : JarvisDesign.secondary
    }
    private var aiIcon: String {
        switch session.phase {
        case .listening: "waveform"
        case .thinking: "cpu"
        case .answering, .speaking: "speaker.wave.2.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "memorychip"
        }
    }

    // MARK: - Helpers

    private var shouldOfferSettings: Bool {
        if session.camera.state == .denied { return true }
        let message = session.errorMessage ?? ""
        return message.contains("权限") || message.contains("系统设置") || message.contains("麦克风")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Voice sheet

    private var voiceSheet: some View {
        NavigationStack {
            List {
                if let err = session.speechOutput.speechError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(JarvisDesign.danger)
                    } header: {
                        Text("语音错误（用于排查）")
                    }
                }
                Section {
                    SecureField("ElevenLabs API Key", text: $elevenKeyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("Voice ID（你克隆声音的 ID）", text: $elevenVoiceIdInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    Button {
                        Task {
                            elevenError = nil
                            let typed = elevenKeyInput.trimmingCharacters(in: .whitespaces)
                            let key = typed.isEmpty ? (KeychainStore.elevenLabsKey ?? "") : typed
                            guard !key.isEmpty else { elevenError = "请先填 API Key"; return }
                            do { elevenVoices = try await ElevenLabsTTS.listVoices(apiKey: key) }
                            catch { elevenError = error.localizedDescription }
                        }
                    } label: {
                        Label("拉取我的声音列表", systemImage: "arrow.down.circle")
                    }

                    ForEach(elevenVoices) { v in
                        Button {
                            elevenVoiceIdInput = v.id
                        } label: {
                            HStack {
                                Text(v.name).foregroundStyle(.primary)
                                Spacer()
                                if elevenVoiceIdInput == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(JarvisDesign.primary)
                                }
                            }
                        }
                    }

                    if let elevenError {
                        Text(elevenError).font(.caption).foregroundStyle(JarvisDesign.danger)
                    }

                    Button {
                        session.speechOutput.applyElevenLabs(key: elevenKeyInput, voiceID: elevenVoiceIdInput)
                        session.speechOutput.previewCurrent()
                    } label: {
                        Label("保存并启用云端语音（试听）", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(elevenVoiceIdInput.trimmingCharacters(in: .whitespaces).isEmpty
                              && KeychainStore.elevenLabsKey == nil)
                } header: {
                    Text("ElevenLabs 云端语音\(session.speechOutput.engine == .elevenLabs ? " · 已启用" : "")")
                } footer: {
                    Text("克隆你自己的声音、随时随地可用（走流量、无需电脑）。到 elevenlabs.io 上传你的声音样本生成声音，得到 Voice ID。API Key 只存本机。只能克隆你有权使用的声音。")
                }

                Section {
                    SecureField("DashScope API Key", text: $qwenKeyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Toggle("国际区（新加坡，克隆需要）", isOn: $qwenIntl)
                    TextField("模型（qwen3-tts-flash / qwen3-tts-vc-2026-01-22）", text: $qwenModelInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("声音（预设如 Cherry，或克隆 voice 名）", text: $qwenVoiceInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        session.speechOutput.applyQwen(key: qwenKeyInput, voice: qwenVoiceInput,
                                                       model: qwenModelInput, intl: qwenIntl)
                        session.speechOutput.previewCurrent()
                    } label: {
                        Label("保存并启用 Qwen 语音（试听）", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(qwenVoiceInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Qwen3-TTS 云端语音（阿里云百炼）\(session.speechOutput.engine == .qwen ? " · 已启用" : "")")
                } footer: {
                    Text("不用电脑，手机走流量。到阿里云百炼拿 DashScope Key。预设声音（如 Cherry）填好即可用；用你克隆的声音：先按官方 enrollment 生成 voice 名，模型填 qwen3-tts-vc-2026-01-22、声音填该 voice 名，并勾选国际区。")
                }

                Section {
                    Button {
                        if session.speechOutput.isRecording {
                            session.speechOutput.stopRecording()
                        } else {
                            session.speechOutput.startRecording()
                        }
                    } label: {
                        Label(session.speechOutput.isRecording ? "停止录音" : "录一段我的声音（10–20 秒）",
                              systemImage: session.speechOutput.isRecording ? "stop.circle.fill" : "mic.circle")
                            .foregroundStyle(session.speechOutput.isRecording ? JarvisDesign.danger : JarvisDesign.primary)
                    }
                    Button {
                        Task { await session.speechOutput.cloneRecordedVoice() }
                    } label: {
                        HStack {
                            Label("用录音克隆并启用", systemImage: "person.wave.2.fill")
                            if session.speechOutput.isCloning {
                                Spacer(); ProgressView()
                            }
                        }
                    }
                    .disabled(session.speechOutput.recordedURL == nil || session.speechOutput.isCloning)

                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("导入音频文件克隆（更高质量）", systemImage: "folder")
                    }
                    .disabled(session.speechOutput.isCloning)

                    if let status = session.speechOutput.cloneStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("克隆我的声音（Qwen3-TTS-VC）")
                } footer: {
                    Text("需要先在上面填好 DashScope 国际区 Key。在安静环境用正常语速录 10–20 秒你自己的声音，点“开始克隆”，约十几秒后会自动用你的声音说话并试听。只能克隆你本人的声音。")
                }

                Section {
                    TextField("http://<Mac的局域网IP>:端口/generate", text: $voiceboxUrlInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                    TextField("Profile ID / 声音名（留空使用第一个）", text: $voiceboxProfileInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        session.speechOutput.applyVoicebox(url: voiceboxUrlInput, profile: voiceboxProfileInput)
                        session.speechOutput.previewCurrent()
                    } label: {
                        Label("保存并启用 Voicebox（试听）", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(voiceboxUrlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Voicebox / 本地 TTS\(session.speechOutput.engine == .voicebox ? " · 已启用" : "")")
                } footer: {
                    Text("在家用：电脑保持 Voicebox 和 voicebox-bridge.mjs 运行，并与手机连接同一 Wi-Fi。地址填写桥接接口（如 http://192.168.x.x:8790/generate），声音名可填写 Voicebox Profile 的名称或 ID；留空时使用列表中的第一个声音。出门再切回 Qwen / ElevenLabs。")
                }
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        session.speechOutput.stop()
                        showVoiceSheet = false
                    }
                }
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { return }
                    await session.speechOutput.cloneFromData(data, mime: mimeType(for: url.pathExtension))
                }
            }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4", "aac": return "audio/mp4"
        default: return "audio/mpeg"
        }
    }

    // MARK: - API key sheet

    private var apiKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-...", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("gpt-4o", text: $modelInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("OpenAI（看图）\(session.hasOpenAIKey ? " · 已配置" : "")")
                } footer: {
                    Text("负责“看”摄像头画面。第一行填 OpenAI API Key，第二行填模型（默认 gpt-4o）。Key 只存本机 Keychain。")
                }

                Section {
                    SecureField("sk-...", text: $deepSeekKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("deepseek-v4-pro", text: $deepSeekModelInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("DeepSeek（答题）\(session.hasDeepSeekKey ? " · 已配置" : "")")
                } footer: {
                    Text("负责“想”和“答”。填了 DeepSeek Key 后：OpenAI 先把画面看成文字，再交给 DeepSeek V4 回答（DeepSeek 自身看不到图）。留空则只用 OpenAI。")
                }

                Section {
                    Button {
                        session.applySettings(openAIKey: keyInput, openAIModel: modelInput,
                                              deepSeekKey: deepSeekKeyInput, deepSeekModel: deepSeekModelInput)
                        showKeySheet = false
                    } label: {
                        Label("保存并启用", systemImage: "checkmark.circle.fill")
                    }

                    if session.apiKeyIsConfigured {
                        Button(role: .destructive) {
                            session.clearAllKeys()
                            keyInput = ""; deepSeekKeyInput = ""
                            showKeySheet = false
                        } label: {
                            Label("清除本机所有 Key", systemImage: "trash")
                        }
                    }
                } footer: {
                    Text("当前模式：\(session.configuration.modeLabel)。两个 Key 都填 = 混合(OpenAI看图+DeepSeek答)；只填 OpenAI = 直连；只填 DeepSeek = 纯文字对话。均按各自账户用量计费。")
                }
            }
            .navigationTitle("模型与 API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showKeySheet = false }
                }
            }
        }
    }
}

#Preview {
    ConversationView()
        .environment(AssistantSession())
}
