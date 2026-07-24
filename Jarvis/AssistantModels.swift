import Foundation

/// High-level state of one hands-free conversation.
enum AssistantPhase: Equatable {
    case idle
    case listening
    case thinking
    case answering
    case speaking
    case completed
    case failed

    var statusText: String {
        switch self {
        case .idle: "待命"
        case .listening: "聆听中"
        case .thinking: "分析中"
        case .answering: "回答中"
        case .speaking: "播报中"
        case .completed: "完成"
        case .failed: "需要处理"
        }
    }
}

struct AssistantRequest: Sendable {
    let question: String
    let imageData: Data
    let conversationSummary: String
    let clientID: String
}

/// One completed exchange, used both for on-screen history and rolling context.
struct ConversationTurn: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String
}

protocol AssistantService: Sendable {
    func streamAnswer(for request: AssistantRequest) -> AsyncThrowingStream<String, Error>
}
