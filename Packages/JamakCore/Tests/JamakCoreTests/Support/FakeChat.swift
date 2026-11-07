import Foundation
@testable import JamakCore

/// 테스트용 LLM. 요청을 기록하고, 순서대로 정한 응답·오류 또는 클로저로 답한다.
final class FakeChat: ChatCompleting, @unchecked Sendable {
    typealias Handler = @Sendable (ChatRequest) async throws -> String

    private let lock = NSLock()
    private var recorded: [ChatRequest] = []
    private var queue: [Result<String, Error>]
    private let handler: Handler?

    /// 요청마다 앞에서부터 하나씩 돌려준다. 다 쓰면 badReply를 던진다.
    init(_ responses: [Result<String, Error>]) {
        self.queue = responses
        self.handler = nil
    }

    convenience init(replies: [String]) {
        self.init(replies.map { .success($0) })
    }

    init(handler: @escaping Handler) {
        self.queue = []
        self.handler = handler
    }

    var requests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: ChatRequest) -> Result<String, Error>? {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return handler == nil && !queue.isEmpty ? queue.removeFirst() : nil
    }

    func complete(_ request: ChatRequest) async throws -> String {
        let next = record(request)
        if let handler { return try await handler(request) }
        guard let next else { throw LLMError.badReply("FakeChat: 준비된 응답이 없어요") }
        return try next.get()
    }
}
