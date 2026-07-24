import Foundation

/// Reads the backend location from the Xcode scheme environment or Info.plist.
/// The OpenAI key never lives in the app; only the backend URL and an optional
/// app token do.
struct AppConfiguration: Sendable {
    let backendURL: URL?
    let backendToken: String?
    let forcesDemoMode: Bool

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

        return AppConfiguration(
            backendURL: validBackendURL(urlString),
            backendToken: token?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            forcesDemoMode: !["false", "0", "no", "off"].contains(demoValue.lowercased())
        )
    }()

    var usesDemoService: Bool {
        forcesDemoMode || backendURL == nil
    }

    var modeLabel: String {
        if forcesDemoMode { return "演示模式" }
        return backendURL == nil ? "后端未配置" : "在线分析"
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
