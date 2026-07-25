import PhotosUI
import SwiftUI
import UIKit

/// Minimal, camera-first Jarvis screen:
///   full-bleed live camera + a translucent answer card + one mic orb.
struct ConversationView: View {
    @Environment(AssistantSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    @State private var photoItem: PhotosPickerItem?
    @State private var showTypeField = false
    @State private var typedText = ""
    @State private var showKeySheet = false
    @State private var keyInput = ""

    var body: some View {
        ZStack {
            cameraBackground
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                diagnosticLine
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                Spacer(minLength: 12)

                conversationCard
                    .padding(.horizontal, 16)

                micDock
                    .padding(.top, 18)
                    .padding(.bottom, 12)
            }
        }
        .task {
            // Start the camera as soon as the view appears. Do NOT gate this on
            // scenePhase: on a cold launch `.task` frequently runs before the
            // scene reports `.active`, and `.onChange` only fires on a *change*,
            // so gating here can leave the camera never started (black screen).
            session.enterForeground()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                session.enterForeground()
            case .background:
                session.enterBackground()
            default:
                break
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
        .sheet(isPresented: $showKeySheet) {
            apiKeySheet
        }
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
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(0.5)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 52, weight: .thin))
                            .foregroundStyle(JarvisDesign.accent.opacity(0.85))
                        Text(cameraPlaceholder)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        cameraRecoveryAction
                    }
                }
            }
        }
    }

    private var cameraPlaceholder: String {
        switch session.camera.state {
        case .denied, .failed:
            session.camera.diagnostic
        case .configuring:
            "正在准备摄像头…"
        default:
            "正在启动实时摄像头…"
        }
    }

    @ViewBuilder
    private var cameraRecoveryAction: some View {
        switch session.camera.state {
        case .denied:
            Button("打开相机权限") { openAppSettings() }
                .buttonStyle(.borderedProminent)
                .tint(JarvisDesign.accent)
        case .failed:
            Button("重试摄像头") { session.camera.start() }
                .buttonStyle(.bordered)
                .tint(JarvisDesign.accent)
        default:
            EmptyView()
        }
    }

    private var shouldOfferSettings: Bool {
        if session.camera.state == .denied { return true }
        let message = session.errorMessage ?? ""
        return message.contains("权限") || message.contains("系统设置") || message.contains("麦克风")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Diagnostics (helps pinpoint device issues at a glance)

    private var diagnosticLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(cameraDotColor)
                .frame(width: 7, height: 7)
            Text(diagnosticText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.35), in: Capsule())
    }

    private var diagnosticText: String {
        "cam:\(cameraStateText) · frames:\(session.camera.previewFrameCount) · phase:\(session.phase.statusText) · \(session.configuration.modeLabel)"
    }

    private var cameraStateText: String {
        switch session.camera.state {
        case .idle: return "idle"
        case .configuring: return "starting"
        case .running: return "running"
        case .denied: return "denied"
        case .failed: return "failed"
        }
    }

    private var cameraDotColor: Color {
        switch session.camera.state {
        case .running: return JarvisDesign.success
        case .configuring, .idle: return JarvisDesign.warning
        case .denied, .failed: return JarvisDesign.danger
        }
    }

    // MARK: - API key sheet (enables anywhere / no-computer use)

    private var apiKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-...", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("OpenAI API Key")
                } footer: {
                    Text(session.apiKeyIsConfigured
                         ? "已配置直连。粘贴新 Key 可替换，留空并点“清除”可移除。填好后 App 直接连 OpenAI，出门走流量即可，无需电脑。"
                         : "粘贴你的 OpenAI API Key。它只保存在本机 Keychain（加密、不进代码/不上传）。填好后 App 直接连 OpenAI，随时随地可用。")
                }

                Section {
                    Button {
                        session.updateAPIKey(keyInput)
                        showKeySheet = false
                    } label: {
                        Label("保存并启用直连", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    if session.apiKeyIsConfigured {
                        Button(role: .destructive) {
                            session.updateAPIKey(nil)
                            keyInput = ""
                            showKeySheet = false
                        } label: {
                            Label("清除本机 Key", systemImage: "trash")
                        }
                    }
                } footer: {
                    Text("在 platform.openai.com 的 API keys 页面创建。需要一个已充值的 OpenAI 账户；按用量计费。")
                }
            }
            .navigationTitle("直连设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showKeySheet = false }
                }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(JarvisDesign.accent)
                Text("JARVIS")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
            }

            StatusPill(phase: session.phase)

            Spacer()

            Menu {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("导入图片", systemImage: "photo")
                }
                Button {
                    showTypeField.toggle()
                } label: {
                    Label("输入文字提问", systemImage: "keyboard")
                }
                Button {
                    keyInput = ""
                    showKeySheet = true
                } label: {
                    Label("直连设置（API Key）", systemImage: "key")
                }
                Button(role: .destructive) {
                    session.clearHistory()
                } label: {
                    Label("清空对话", systemImage: "trash")
                }
                Divider()
                Text(session.configuration.modeLabel)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
                    .background(.black.opacity(0.3), in: Circle())
            }
        }
    }

    // MARK: - Conversation card

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                        if session.phase == .thinking {
                            thinkingRow.id("current")
                        }

                        if session.currentQuestion.isEmpty && session.history.isEmpty && session.phase != .thinking {
                            emptyState
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                .onChange(of: session.answerText) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("current", anchor: .bottom)
                    }
                }
            }

            if session.phase == .listening {
                listeningBar
            }

            if showTypeField {
                typeBar
            }
        }
        .frame(maxHeight: 340)
        .jarvisPanel(radius: 26)
    }

    private var pastTurns: [ConversationTurn] {
        // The active/most-recent turn is rendered separately in the "current"
        // block, so drop it here to avoid showing it twice.
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
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 2)
                Text(question)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(dim ? 0.55 : 0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !answer.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(JarvisDesign.accent.opacity(dim ? 0.5 : 1))
                        .padding(.top, 2)
                    answerText(answer, dim: dim, streaming: streaming)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerText(_ text: String, dim: Bool, streaming: Bool) -> some View {
        let rendered: Text
        if let markdown = try? AttributedString(markdown: text) {
            rendered = Text(markdown)
        } else {
            rendered = Text(text)
        }
        return rendered
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.white.opacity(dim ? 0.6 : 0.98))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                if streaming {
                    Circle()
                        .fill(JarvisDesign.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 10, y: -4)
                }
            }
    }

    private var thinkingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(JarvisDesign.accent)
            Text("正在看画面并核对信息…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你好，我是 JARVIS")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("对准你想问的东西，点一下麦克风，然后直接开口，例如：\n“这是什么？”“这个按钮干嘛用的？”“帮我查下这个型号的参数。”")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(4)
        }
    }

    private var listeningBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.callout)
                .foregroundStyle(JarvisDesign.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(session.liveTranscript.isEmpty ? "请开口说话…" : session.liveTranscript)
                .font(.callout)
                .foregroundStyle(.white.opacity(session.liveTranscript.isEmpty ? 0.5 : 0.95))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.25))
    }

    private var typeBar: some View {
        HStack(spacing: 10) {
            TextField("输入问题…", text: $typedText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .submitLabel(.send)
                .onSubmit(sendTyped)
            Button(action: sendTyped) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(typedText.isEmpty ? .white.opacity(0.3) : JarvisDesign.accent)
            }
            .disabled(typedText.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.3))
    }

    private func sendTyped() {
        let text = typedText
        typedText = ""
        session.submitTypedQuestion(text)
    }

    // MARK: - Mic dock

    private var micDock: some View {
        VStack(spacing: 8) {
            Button(action: primaryAction) {
                ZStack {
                    Circle()
                        .fill(orbColor.opacity(0.18))
                        .frame(width: 92, height: 92)
                    Circle()
                        .stroke(orbColor.opacity(0.9), lineWidth: 2)
                        .frame(width: 78, height: 78)
                    Image(systemName: orbIcon)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(orbColor)
                }
                .shadow(color: orbColor.opacity(0.5), radius: session.isConversationActive ? 22 : 8)
                .scaleEffect(session.phase == .listening ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: session.phase == .listening)
            }
            .buttonStyle(.plain)

            Text(dockLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func primaryAction() {
        switch session.phase {
        case .speaking, .answering:
            session.stopSpeaking()
        default:
            session.toggleConversation()
        }
    }

    private var orbColor: Color {
        switch session.phase {
        case .listening: JarvisDesign.accent
        case .thinking, .answering: JarvisDesign.warning
        case .speaking: JarvisDesign.success
        case .failed: JarvisDesign.danger
        default: session.isConversationActive ? JarvisDesign.accent : .white
        }
    }

    private var orbIcon: String {
        switch session.phase {
        case .listening: "mic.fill"
        case .thinking: "ellipsis"
        case .answering, .speaking: "stop.fill"
        default: session.isConversationActive ? "mic.fill" : "mic"
        }
    }

    private var dockLabel: String {
        switch session.phase {
        case .listening: "正在聆听 · 说完停顿即可"
        case .thinking: "分析中…"
        case .answering, .speaking: "点击打断"
        case .failed: "点击重试"
        default: session.isConversationActive ? "点击结束对话" : "点击开始语音对话"
        }
    }
}

#Preview {
    ConversationView()
        .environment(AssistantSession())
}
