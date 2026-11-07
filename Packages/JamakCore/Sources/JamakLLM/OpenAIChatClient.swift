import Foundation
import os
import JamakCore

/// OpenAI 호환 `/chat/completions`, `/models` 클라이언트.
///
/// 선택 필드(`response_format`, `temperature`, 응답 길이 상한)를 함께 보낸다.
/// 서버가 400으로 거절하면 오류 메시지에 이름이 나온 필드를 이 인스턴스에서 빼고 다시 보낸다.
/// 이름이 나오지 않은 400이면 `response_format`을 뺀다(보냈을 때만). 뺀 필드는 이후 요청에도 계속 뺀다.
///
/// `stream: true`와 `stream_options.include_usage`를 보내 SSE로 받는다. 서버가 거절하면 같은 규칙으로 빠지고
/// 한 번에 받는다. 응답의 `Content-Type`이 `text/event-stream`이 아니면 스트림을 요청했어도 한 번에 받은 것으로 읽는다.
///
/// 응답 길이 상한은 OpenAI 새 모델이 받는 `max_completion_tokens`와 Ollama 등이 받는 `max_tokens`를
/// 둘 다 보낸다. 받지 않는 쪽은 서버가 무시하거나, 거절하면 위 규칙으로 빠진다.
public final class OpenAIChatClient: ChatCompleting, Sendable {
    /// 서버가 거절하면 뺄 수 있는 선택 필드.
    enum OptionalField: String, CaseIterable, Sendable {
        case responseFormat = "response_format"
        case temperature
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case stream
        case streamOptions = "stream_options"
    }

    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxOutputTokens: Int
    /// 서버가 거절해서 뺀 필드. 여러 작업이 동시에 읽고 쓰므로 잠금으로 지킨다.
    private let rejected = OSAllocatedUnfairLock(initialState: Set<OptionalField>())

    /// 응답 길이 상한(토큰). 모델이 끝없이 쓰는 일을 막는다.
    public static let defaultMaxOutputTokens = 8192

    public init(baseURL: URL, apiKey: String?, session: URLSession = .shared, timeout: TimeInterval = 300,
                maxOutputTokens: Int = OpenAIChatClient.defaultMaxOutputTokens) {
        self.baseURL = baseURL
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.session = session
        self.timeout = timeout
        self.maxOutputTokens = maxOutputTokens
    }

    public func complete(_ request: ChatRequest) async throws -> String {
        try await complete(request, observer: nil)
    }

    /// `observer`로 요청 단계와 사용량을 알린다. 거절 필드 재시도도 요청마다 따로 알린다.
    public func complete(_ request: ChatRequest, observer: ChatObserver?) async throws -> String {
        // 필드 수만큼 거절당하면 더 뺄 것이 없으므로 그 안에서 끝난다.
        for _ in 0...OptionalField.allCases.count {
            let skipped = rejected.withLock { $0 }
            let fields = Self.fields(for: request, skipping: skipped)
            do {
                return try await send(request, fields: fields, observer: observer)
            } catch LLMError.http(let status, let message) where status == 400 {
                guard let field = Self.rejectedField(in: message, sent: fields) else { throw LLMError.http(status: status, message: message) }
                rejected.withLock { _ = $0.insert(field) }
            }
        }
        throw LLMError.badReply("서버가 요청 필드를 계속 거절해요")
    }

    /// 이번 요청에 보낼 선택 필드.
    static func fields(for request: ChatRequest, skipping skipped: Set<OptionalField>) -> Set<OptionalField> {
        var fields = Set(OptionalField.allCases).subtracting(skipped)
        if !request.wantsJSON { fields.remove(.responseFormat) }
        if !fields.contains(.stream) { fields.remove(.streamOptions) }
        return fields
    }

    /// 400 메시지가 거절한 필드. 보낸 필드 중 메시지에 가장 먼저 나오는 것을 고른다
    /// ("'max_tokens' … Use 'max_completion_tokens' instead"처럼 둘이 함께 나오는 경우 때문).
    /// 이름은 낱말 전체로만 찾는다("stream_options"·"streaming"·"upstream" 속의 "stream"은 `stream`이 아니다).
    /// 이름이 없으면 `response_format`(보냈을 때만). 해당이 없으면 nil.
    static func rejectedField(in message: String, sent: Set<OptionalField>) -> OptionalField? {
        let lower = message.lowercased()
        let named = sent.compactMap { field -> (OptionalField, String.Index)? in
            guard let index = firstWord(field.rawValue, in: lower) else { return nil }
            return (field, index)
        }
        if let first = named.min(by: { $0.1 < $1.1 }) { return first.0 }
        return sent.contains(.responseFormat) ? .responseFormat : nil
    }

    /// `word`가 앞뒤에 글자·숫자·`_`가 붙지 않은 채 처음 나오는 위치.
    private static func firstWord(_ word: String, in text: String) -> String.Index? {
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var from = text.startIndex
        while let range = text.range(of: word, range: from..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isWordChar) ?? false) && !(after.map(isWordChar) ?? false) { return range.lowerBound }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }

    public func models() async throws -> [String] {
        let urlRequest = makeRequest(path: "models", method: "GET")
        let data = try await perform(urlRequest)
        struct Reply: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw LLMError.badReply("모델 목록을 읽을 수 없어요")
        }
        return reply.data.map(\.id).sorted()
    }

    // MARK: - 내부

    private func send(_ request: ChatRequest, fields: Set<OptionalField>, observer: ChatObserver?) async throws -> String {
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(Self.encode),
        ]
        for field in fields {
            switch field {
            case .responseFormat: body[field.rawValue] = ["type": "json_object"]
            case .temperature: body[field.rawValue] = request.temperature
            case .maxTokens, .maxCompletionTokens: body[field.rawValue] = maxOutputTokens
            case .stream: body[field.rawValue] = true
            case .streamOptions: body[field.rawValue] = ["include_usage": true]
            }
        }
        var urlRequest = makeRequest(path: "chat/completions", method: "POST")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        observer?.phase(.sending)
        let (bytes, http) = try await openBytes(urlRequest)
        guard http.statusCode == 200 else {
            // 오류 응답은 본문에 사용량이 있을 때만 알린다(필드 거절·429 같은 비용 없는 오류는 요청으로 세지 않는다).
            let data = try await collect(bytes, limit: Self.errorBodyLimit)
            if let usage = Self.usage(in: data) { observer?.finished(usage) }
            throw Self.httpError(status: http.statusCode, data: data)
        }
        let isStream = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        let reply = isStream
            ? try await readStream(bytes, observer: observer)
            : try await readWhole(bytes, observer: observer)
        observer?.finished(reply.usage)

        // 생각만 하다 상한에 걸린 응답(내용 없음)도 잘림으로 알린다.
        if reply.finishReason == "length" {
            throw LLMError.badReply("응답이 최대 길이(\(maxOutputTokens)토큰)에서 잘렸어요")
        }
        guard let content = reply.content else {
            throw LLMError.badReply(reply.problem ?? "응답에 choices[0].message.content가 없어요")
        }
        return content
    }

    /// 읽어 낸 응답. `content`가 nil이면 `problem`이 그 까닭이다.
    private struct Reply {
        var content: String?
        var finishReason: String?
        var usage: ChatUsage?
        var problem: String?
    }

    /// 응답 JSON의 `usage`. 스트림 조각과 한 번에 받은 응답, 오류 본문이 같은 모양이다.
    private struct UsageBody: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        var chatUsage: ChatUsage? {
            if prompt_tokens == nil && completion_tokens == nil { return nil }
            return ChatUsage(input: prompt_tokens ?? 0, output: completion_tokens ?? 0)
        }
    }

    private static func usage(in data: Data) -> ChatUsage? {
        struct Body: Decodable { let usage: UsageBody? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.usage?.chatUsage
    }

    /// 한 번에 받는 응답(스트림을 쓰지 않거나 서버가 무시한 경우).
    private func readWhole(_ bytes: URLSession.AsyncBytes, observer: ChatObserver?) async throws -> Reply {
        observer?.phase(.receiving)
        let data = try await collect(bytes, limit: nil)
        struct Body: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
            let usage: UsageBody?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            return Reply(content: nil, usage: Self.usage(in: data))
        }
        let choice = body.choices.first
        return Reply(content: choice?.message.content, finishReason: choice?.finish_reason, usage: body.usage?.chatUsage)
    }

    /// SSE 스트림. `data:` 줄마다 JSON 조각 하나이고 `data: [DONE]`에서 끝난다.
    private func readStream(_ bytes: URLSession.AsyncBytes, observer: ChatObserver?) async throws -> Reply {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            struct Failure: Decodable { let message: String? }
            let choices: [Choice]?
            let usage: UsageBody?
            let error: Failure?
        }
        var reply = Reply()
        var text = ""
        var gotContent = false
        var receiving = false
        var sawDone = false
        do {
            for try await line in bytes.lines {
                // 빈 줄, 주석(`:`), `event:`·`id:` 같은 다른 줄은 건너뛴다.
                guard line.hasPrefix("data:") else { continue }
                var payload = line.dropFirst("data:".count)
                if payload.first == " " { payload = payload.dropFirst() }
                // 빈 `data:`는 연결 유지용이다.
                let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if !receiving { receiving = true; observer?.phase(.receiving) }
                if trimmed == "[DONE]" { sawDone = true; break }
                guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
                    reply.problem = "스트림 조각을 읽을 수 없어요"
                    gotContent = false
                    break
                }
                if let error = chunk.error {
                    reply.problem = "서버가 스트림 도중 오류를 보냈어요: \(error.message ?? "알 수 없음")"
                    gotContent = false
                    break
                }
                if let usage = chunk.usage?.chatUsage { reply.usage = usage }
                // reasoning·reasoning_content는 본문에 넣지 않는다(단계 판정은 위에서 첫 조각으로 끝났다).
                if let choice = chunk.choices?.first {
                    if let piece = choice.delta?.content { text += piece; gotContent = true }
                    if let reason = choice.finish_reason { reply.finishReason = reason }
                }
            }
        } catch {
            throw mapTransport(error)
        }
        // `[DONE]`도 `finish_reason`도 없이 끝났으면 중간에 끊긴 것이다.
        if reply.problem == nil && !sawDone && reply.finishReason == nil {
            reply.problem = "스트림이 중간에 끊겼어요"
            gotContent = false
        }
        if gotContent {
            reply.content = text
        } else if reply.problem == nil {
            reply.problem = "스트림에 응답 내용이 없어요"
        }
        return reply
    }

    /// 오류 본문 상한. 그보다 긴 본문은 앞부분만 읽는다.
    private static let errorBodyLimit = 64 * 1024

    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int?) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if let limit, data.count >= limit { break }
            }
        } catch {
            throw mapTransport(error)
        }
        return data
    }

    private func openBytes(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapTransport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badReply("HTTP 응답이 아니에요")
        }
        return (bytes, http)
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        // 끝의 `/` 유무와 상관없이 같은 주소가 되도록 직접 잇는다.
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var request = URLRequest(url: URL(string: base + "/" + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badReply("HTTP 응답이 아니에요")
        }
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    /// 전송 중 오류를 앱 오류로 바꾼다. 취소는 `CancellationError`다.
    private func mapTransport(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
             .dnsLookupFailed, .cannotLoadFromNetwork, .secureConnectionFailed:
            return LLMError.unreachable(baseURL.absoluteString)
        case .timedOut:
            return LLMError.timedOut
        case .badServerResponse, .cannotParseResponse:
            return LLMError.badReply("서버 응답이 올바르지 않아요 (\(error.localizedDescription))")
        default:
            if Task.isCancelled { return CancellationError() }
            return error
        }
    }

    /// HTTP 오류. 문맥 길이 초과(`context_length_exceeded` 코드나 "maximum context length" 메시지)는 `contextTooLong`.
    static func httpError(status: Int, data: Data) -> LLMError {
        let message = errorMessage(from: data)
        var code = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let c = err["code"] as? String {
            code = c
        }
        if code == "context_length_exceeded" || message.lowercased().contains("maximum context length") {
            return .contextTooLong
        }
        return .http(status: status, message: message)
    }

    /// 응답 JSON의 `error.message`, 없으면 본문 앞 300자.
    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        return String(String(decoding: data, as: UTF8.self).prefix(300))
    }

    private static func encode(_ message: ChatMessage) -> [String: Any] {
        let hasImage = message.parts.contains { if case .imageJPEG = $0 { true } else { false } }
        if !hasImage {
            let text = message.parts.compactMap { part -> String? in
                if case .text(let s) = part { s } else { nil }
            }.joined(separator: "\n")
            return ["role": message.role.rawValue, "content": text]
        }
        let parts: [[String: Any]] = message.parts.map { part in
            switch part {
            case .text(let s):
                return ["type": "text", "text": s]
            case .imageJPEG(let data):
                return ["type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]]
            }
        }
        return ["role": message.role.rawValue, "content": parts]
    }
}

/// 요청 하나의 단계. 보낸 뒤 첫 조각까지가 `sending`, 그 뒤 끝까지가 `receiving`이다.
public enum ChatPhase: Sendable, Equatable { case sending, receiving }

/// 요청의 진행과 사용량을 듣는다. 메인 액터 밖에서 불린다.
public struct ChatObserver: Sendable {
    public var phase: @Sendable (ChatPhase) -> Void
    /// 응답이 온 시도가 끝날 때 한 번(성공·스트림 응답·잘림). 오류 응답은 본문에 usage가 있을 때만 부른다.
    /// 성공한 응답에서 usage를 못 받았으면 nil. 연결 실패·취소·usage 없는 오류 응답이면 부르지 않는다.
    public var finished: @Sendable (ChatUsage?) -> Void

    public init(phase: @escaping @Sendable (ChatPhase) -> Void, finished: @escaping @Sendable (ChatUsage?) -> Void) {
        self.phase = phase
        self.finished = finished
    }
}
