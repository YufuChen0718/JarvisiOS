import Foundation

/// Local, offline stand-in so the full voice + camera loop works with no API key
/// and never uploads an image.
struct DemoAssistantService: AssistantService {
    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let response = """
                这是本地演示模式，我不会上传画面，也不会真正联网搜索。你刚才问的是“\(request.question)”。

                连接后端后，我就能看你摄像头里的实物、联网查资料，并用语音把结论念给你听。配置方法见 README。
                """
                do {
                    for chunk in response.chunked(maxLength: 8) {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(32))
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Talks to the secure Node backend, which holds the OpenAI key and streams the
/// Responses API (with web search) back as Server-Sent Events.
struct BackendAssistantService: AssistantService {
    let baseURL: URL
    let token: String?

    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = baseURL.appendingPathComponent("answer")
                    let payload = BackendPayload(
                        question: request.question,
                        imageBase64: request.imageData.base64EncodedString(),
                        conversationSummary: request.conversationSummary,
                        clientID: request.clientID
                    )

                    var urlRequest = URLRequest(url: endpoint)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 120
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let token {
                        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    urlRequest.httpBody = try JSONEncoder().encode(payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ServiceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let data = try await collectErrorBody(from: bytes)
                        let backendError = try? JSONDecoder().decode(BackendErrorResponse.self, from: data)
                        throw ServiceError.backend(
                            status: http.statusCode,
                            message: backendError?.displayMessage
                        )
                    }

                    var receivedOutput = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard raw != "[DONE]", let data = raw.data(using: .utf8) else { continue }

                        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
                        if event.type == "response.output_text.delta", let delta = event.delta {
                            receivedOutput = true
                            continuation.yield(delta)
                        } else if event.type == "response.refusal.delta", let delta = event.delta {
                            receivedOutput = true
                            continuation.yield(delta)
                        } else if event.type == "error" || event.type == "response.failed" {
                            throw ServiceError.remote(
                                event.error?.message
                                    ?? event.response?.error?.message
                                    ?? "服务返回未知错误。"
                            )
                        }
                    }
                    guard receivedOutput else { throw ServiceError.emptyResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ServiceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: ServiceError.network(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Calls OpenAI directly from the device — no server required. The key lives in
/// the Keychain, so the app works anywhere over cellular with no computer on.
/// Trade-off: the key ships with the app on THIS device only (personal use).
struct DirectOpenAIService: AssistantService {
    let apiKey: String
    let model: String
    var enableWebSearch: Bool = true

    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 120
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: makeBody(request))

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ServiceError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let data = try await collectErrorBody(from: bytes)
                        throw ServiceError.backend(status: http.statusCode, message: openAIErrorMessage(data))
                    }

                    var receivedOutput = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard raw != "[DONE]", let data = raw.data(using: .utf8) else { continue }

                        let event = try JSONDecoder().decode(StreamEvent.self, from: data)
                        if event.type == "response.output_text.delta", let delta = event.delta {
                            receivedOutput = true
                            continuation.yield(delta)
                        } else if event.type == "response.refusal.delta", let delta = event.delta {
                            receivedOutput = true
                            continuation.yield(delta)
                        } else if event.type == "error" || event.type == "response.failed" {
                            throw ServiceError.remote(
                                event.error?.message
                                    ?? event.response?.error?.message
                                    ?? "OpenAI 返回未知错误。"
                            )
                        }
                    }
                    guard receivedOutput else { throw ServiceError.emptyResponse }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ServiceError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: ServiceError.network(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeBody(_ request: AssistantRequest) -> [String: Any] {
        let instructions = [
            "你是运行在 iPhone 上的专业视觉识别助手 JARVIS，通过手机后置摄像头看用户面前的实物。",
            "先用一句话直接回答，再给最多三条真正有操作价值的要点。",
            "只陈述当前画面和会话上下文支持的事实；看不清时明确说明，并建议靠近、补光或换角度。",
            "需要最新价格、规格、型号参数、新闻或事实核查时使用联网搜索，并简要说明依据。",
            "涉及医疗、电气、机械、化学品、交通或人身安全时，先提示停止危险操作并咨询专业人员。",
            "默认用简洁自然的中文回答，避免冗长格式，方便手机语音朗读。",
        ].joined(separator: "\n")

        let context = request.conversationSummary.isEmpty
            ? "当前问题：\(request.question)"
            : "最近的对话（供指代消解）：\n\(request.conversationSummary)\n\n当前问题：\(request.question)"

        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "max_output_tokens": 1200,
            "instructions": instructions,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": context],
                        [
                            "type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(request.imageData.base64EncodedString())",
                            "detail": "high",
                        ],
                    ],
                ],
            ],
        ]
        if enableWebSearch {
            body["tools"] = [["type": "web_search"]]
        }
        return body
    }
}

private func openAIErrorMessage(_ data: Data) -> String? {
    struct Payload: Decodable {
        struct Err: Decodable { let message: String? }
        let error: Err?
    }
    return (try? JSONDecoder().decode(Payload.self, from: data))?.error?.message
}

private struct BackendPayload: Encodable {
    let question: String
    let imageBase64: String
    let conversationSummary: String
    let clientID: String
}

private struct StreamEvent: Decodable {
    struct RemoteError: Decodable { let message: String? }
    struct RemoteResponse: Decodable { let error: RemoteError? }
    let type: String
    let delta: String?
    let error: RemoteError?
    let response: RemoteResponse?
}

private struct BackendErrorResponse: Decodable {
    let error: String?
    let detail: String?

    var displayMessage: String? {
        [error, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "：")
            .nonEmpty
    }
}

private func collectErrorBody(from bytes: URLSession.AsyncBytes, limit: Int = 32_768) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
        guard data.count < limit else { break }
        data.append(byte)
    }
    return data
}

enum ServiceError: LocalizedError {
    case invalidResponse
    case backend(status: Int, message: String?)
    case remote(String)
    case emptyResponse
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "后端返回了无法识别的网络响应。"
        case .backend(let status, let message):
            message.map { "后端错误（HTTP \(status)）：\($0)" }
                ?? "后端连接失败（HTTP \(status)）。"
        case .remote(let message): message
        case .emptyResponse:
            "后端连接成功，但没有收到可显示的回答。请检查模型和流式事件配置。"
        case .network(let error):
            Self.networkMessage(error)
        }
    }

    private static func networkMessage(_ error: URLError) -> String {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost:
            "无法连接 JARVIS 后端。请先在 Mac 启动 start-backend.command，并确认 iPhone 与 Mac 使用同一 Wi-Fi。"
        case .timedOut:
            "后端响应超时。请检查 Mac 网络、OpenAI API 状态或稍后重试。"
        case .notConnectedToInternet, .networkConnectionLost:
            "网络连接不可用或已经中断。"
        case .appTransportSecurityRequiresSecureConnection:
            "iOS 阻止了不安全的后端地址。局域网调试请使用工程中配置的 Mac .local 地址，生产环境请使用 HTTPS。"
        default:
            "后端网络错误：\(error.localizedDescription)"
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }

    func chunked(maxLength: Int) -> [String] {
        guard maxLength > 0 else { return [self] }
        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
            result.append(String(self[start..<end]))
            start = end
        }
        return result
    }
}
