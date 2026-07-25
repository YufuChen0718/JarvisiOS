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
            "你是 JARVIS，运行在用户 iPhone 上的智能助手，能通过后置摄像头看到用户面前的画面。",
            "像一个博学、可靠的专家一样回答：既利用画面里的视觉信息，也充分运用你自己的知识，给出准确、有用的答案。",
            "识别物体时大胆给出最可能的判断，并简要说明把握程度；不要动不动就说“看不清”，只有确实无法判断时才请用户靠近、补光或换个角度。",
            "根据问题自动决定回答的深度与方式：简单问题用一两句话直接回答；复杂、专业或需要推理的问题，先想清楚再给出有条理、准确的解释。",
            "当问题涉及最新信息、价格、新闻、具体型号或规格、事实核查等需要查证的内容时，主动使用联网搜索工具，并说明关键依据。",
            "如果画面和问题不匹配，或用户其实是在闲聊、问常识，就正常像聊天助手一样回答，不必强行描述画面。",
            "用自然、口语化的中文回答（会被语音朗读），可长可短：简单就简短，需要时可以详细，但避免大段列表和符号堆砌。",
            "涉及医疗、用药、电气、机械、化学品、交通或人身安全的操作，先提醒风险并建议咨询专业人士。",
        ].joined(separator: "\n")

        let context = request.conversationSummary.isEmpty
            ? "当前问题：\(request.question)"
            : "最近的对话（供指代消解）：\n\(request.conversationSummary)\n\n当前问题：\(request.question)"

        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "max_output_tokens": 2000,
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

// MARK: - Hybrid (OpenAI vision -> DeepSeek reasoning)

/// OpenAI's API cannot be replaced by DeepSeek for a camera app because the
/// DeepSeek API has no image input. This service bridges the two: OpenAI "sees"
/// the frame and writes a description, then DeepSeek V4 answers from it.
struct HybridVisionService: AssistantService {
    let openAIKey: String
    let visionModel: String
    let deepseekKey: String
    let deepseekModel: String

    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. OpenAI vision -> textual description of the frame.
                    let dataURL = "data:image/jpeg;base64,\(request.imageData.base64EncodedString())"
                    let visionMessages: [[String: Any]] = [
                        ["role": "system", "content": "你是视觉分析模块。仔细观察图片并结合用户的问题，用中文客观、详细地描述画面中的相关信息：物体是什么、上面的品牌/型号/文字、颜色材质、状态、数字读数、周围环境等一切有助于回答的细节。只描述，不下最终结论、不给建议。"],
                        ["role": "user", "content": [
                            ["type": "text", "text": "用户的问题：\(request.question)"],
                            ["type": "image_url", "image_url": ["url": dataURL]],
                        ]],
                    ]
                    let description = try await chatCompletionOnce(
                        baseURL: "https://api.openai.com/v1",
                        apiKey: openAIKey, model: visionModel, messages: visionMessages)

                    try Task.checkCancellation()

                    // 2. DeepSeek reasons over the description + question.
                    let messages = deepSeekMessages(
                        question: request.question,
                        summary: request.conversationSummary,
                        description: description)
                    try await streamChatCompletion(
                        baseURL: "https://api.deepseek.com",
                        apiKey: deepseekKey, model: deepseekModel,
                        messages: messages, continuation: continuation)
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

/// DeepSeek text-only (used when no OpenAI key exists — no image understanding).
struct DeepSeekTextService: AssistantService {
    let apiKey: String
    let model: String

    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messages = deepSeekMessages(
                        question: request.question,
                        summary: request.conversationSummary,
                        description: nil)
                    try await streamChatCompletion(
                        baseURL: "https://api.deepseek.com",
                        apiKey: apiKey, model: model,
                        messages: messages, continuation: continuation)
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

private func deepSeekMessages(question: String, summary: String, description: String?) -> [[String: Any]] {
    var system = [
        "你是 JARVIS，用户的智能助手。",
        "像博学可靠的专家一样回答：结合已知信息和你自己的知识，给出准确有用的答案。",
        "根据问题自动决定深度：简单问题简答；复杂或需要推理的问题先想清楚再有条理地详答。",
        "用自然口语化的中文回答（会被语音朗读），避免大段列表和符号堆砌。",
        "涉及医疗、用药、电气、机械、化学品、交通或人身安全的操作，先提醒风险并建议咨询专业人士。",
    ]
    if description != nil {
        system.insert("你看不到原始图片，下面的“画面描述”是视觉模块根据用户手机摄像头画面生成的，请据此回答；若描述与问题无关就当作普通提问。", at: 1)
    }

    var userText = ""
    if let description, !description.isEmpty {
        userText += "【画面描述】\n\(description)\n\n"
    }
    if !summary.isEmpty {
        userText += "【最近的对话】\n\(summary)\n\n"
    }
    userText += "【我的问题】\n\(question)"

    return [
        ["role": "system", "content": system.joined(separator: "\n")],
        ["role": "user", "content": userText],
    ]
}

// MARK: - OpenAI-compatible chat/completions helpers (OpenAI + DeepSeek)

private func chatCompletionOnce(baseURL: String, apiKey: String, model: String,
                                messages: [[String: Any]]) async throws -> String {
    var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "messages": messages, "stream": false,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        throw ServiceError.backend(status: http.statusCode, message: openAIErrorMessage(data))
    }
    struct Resp: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        let choices: [Choice]
    }
    let decoded = try JSONDecoder().decode(Resp.self, from: data)
    return decoded.choices.first?.message.content ?? ""
}

private func streamChatCompletion(baseURL: String, apiKey: String, model: String,
                                  messages: [[String: Any]],
                                  continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
    var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "messages": messages, "stream": true,
    ])
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let data = try await collectErrorBody(from: bytes)
        throw ServiceError.backend(status: http.statusCode, message: openAIErrorMessage(data))
    }
    struct Chunk: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
        let choices: [Choice]
    }
    var received = false
    for try await line in bytes.lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data:") else { continue }
        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard raw != "[DONE]", let data = raw.data(using: .utf8) else { continue }
        if let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
           let piece = chunk.choices.first?.delta.content, !piece.isEmpty {
            received = true
            continuation.yield(piece)
        }
    }
    if !received { throw ServiceError.emptyResponse }
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
