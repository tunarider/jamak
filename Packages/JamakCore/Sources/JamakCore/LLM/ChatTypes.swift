import Foundation

/// 메시지 조각: 글 또는 JPEG 이미지.
public enum ChatPart: Equatable, Sendable {
    case text(String)
    case imageJPEG(Data)
}

public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var parts: [ChatPart]

    public init(role: Role, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }

    public static func system(_ s: String) -> ChatMessage {
        ChatMessage(role: .system, parts: [.text(s)])
    }

    /// 글 뒤에 이미지를 붙인 사용자 메시지.
    public static func user(_ s: String, images: [Data] = []) -> ChatMessage {
        ChatMessage(role: .user, parts: [.text(s)] + images.map { .imageJPEG($0) })
    }
}

public struct ChatRequest: Equatable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double
    public var wantsJSON: Bool

    public init(model: String, messages: [ChatMessage], temperature: Double, wantsJSON: Bool = true) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.wantsJSON = wantsJSON
    }
}

public protocol ChatCompleting: Sendable {
    func complete(_ request: ChatRequest) async throws -> String
}

public enum LLMError: Error, Equatable {
    case unreachable(String)            // base URL
    case http(status: Int, message: String)
    case timedOut
    case badReply(String)               // 파싱·검증 실패, 재시도 대상
    case contextTooLong                 // 요청이 모델 문맥 길이를 넘음. 같은 요청을 다시 보내도 소용없다

    /// http 5xx, 시간 초과, 깨진 응답만 다시 시도한다.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status >= 500
        case .timedOut, .badReply: return true
        case .unreachable, .contextTooLong: return false
        }
    }
}

extension LLMError {
    /// 사용자에게 보이는 한국어 문구. 설정 화면의 연결 확인과 단계 실패 메시지가 함께 쓴다.
    public var koreanDescription: String {
        switch self {
        case .unreachable(let url): "서버에 연결할 수 없어요 (\(url))"
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .timedOut: "시간이 초과됐어요"
        case .badReply(let detail): "서버 응답을 이해할 수 없어요: \(detail)"
        case .contextTooLong: "한 번에 보낼 글이 모델이 받을 수 있는 길이를 넘었어요"
        }
    }
}
