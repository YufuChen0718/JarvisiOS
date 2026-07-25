import Foundation

/// Reads the backend location from the Xcode scheme environment or Info.plist.
/// The OpenAI key never lives in the app; only the backend URL and an optional
/// app token do.
struct AppConfiguration: Sendable {
    let backendURL: URL?
    let backendToken: String?
    let forcesDemoMode: Bool
    /// Optional key baked in at build time (env or Info.plist). The Keychain
    /// value entered in-app takes priority over this — see effectiveOpenAIKey.
    let bundledOpenAIKey: String?
    let openAIModel: String
    let webSearchEnabled: Bool

    static let current: AppConfiguration = {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]

        let urlString = environment["JARVIS_BACKEND_URL"]
            ?? info["JarvisBackendURL"] as? String
            ?? ""
        let token = environment["JARVIS_BACKEND_TOKEN"]
        let demoValue = environment["JARVIS_DEMO_MODE"]
            ?? (info["JarvisDemoMode"] as? Bool).map(String.init)
            ?? "true"

        let bundledKey = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? (info["OpenAIAPIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let modelString = environment["OPENAI_MODEL"]?.nonEmpty
            ?? (info["OpenAIModel"] as? String)?.nonEmpty
            ?? "gpt-4o"
        let webSearchValue = environment["OPENAI_WEB_SEARCH"]
            ?? (info["OpenAIWebSearch"] as? Bool).map(String.init)
            ?? "true"

        return AppConfiguration(
            backendURL: validBackendURL(urlString),
            backendToken: token?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            forcesDemoMode: !["false", "0", "no", "off"].contains(demoValue.lowercased()),
            bundledOpenAIKey: bundledKey,
            openAIModel: modelString,
            webSearchEnabled: !["false", "0", "no", "off"].contains(webSearchValue.lowercased())
        )
    }()

    /// The key actually used at runtime: an in-app (Keychain) key wins, then any
    /// build-time key. When non-nil, the app talks straight to OpenAI and needs
    /// no computer/server.
    var effectiveOpenAIKey: String? {
        KeychainStore.apiKey ?? bundledOpenAIKey
    }

    var usesDirectService: Bool {
        effectiveOpenAIKey != nil
    }

    var usesDemoService: Bool {
        forcesDemoMode || backendURL == nil
    }

    var modeLabel: String {
        if usesDirectService { return "直连模式" }
        if forcesDemoMode { return "演示模式" }
        return backendURL == nil ? "未配置" : "局域网后端"
    }

    private static func validBackendURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
