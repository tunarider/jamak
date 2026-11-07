import Foundation
import Testing
import JamakCore
@testable import JamakLLM

@Suite(.serialized)
struct OpenAIChatClientTests {
    static let ok = #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#
    let base = URL(string: "http://localhost:11434/v1")!

    func client(key: String? = "sk-test", base: URL? = nil) -> OpenAIChatClient {
        OpenAIChatClient(baseURL: base ?? self.base, apiKey: key, session: StubProtocol.makeSession())
    }

    func json(_ i: Int) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StubProtocol.requests[i].body) as? [String: Any])
    }

    @Test func sendsChatCompletionBody() async throws {
        StubProtocol.reset([.http(200, Self.ok)])
        let req = ChatRequest(model: "m1", messages: [.system("sys"), .user("hello")], temperature: 0.2)
        let out = try await client().complete(req)
        #expect(out == "hi")
        let sent = StubProtocol.requests[0]
        #expect(sent.request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(0)
        #expect(body["model"] as? String == "m1")
        #expect(body["temperature"] as? Double == 0.2)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let msgs = try #require(body["messages"] as? [[String: Any]])
        #expect(msgs[0]["role"] as? String == "system")
        #expect(msgs[1]["content"] as? String == "hello")
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test func joinsTrailingSlashBaseURL() async throws {
        StubProtocol.reset([.http(200, Self.ok)])
        _ = try await client(base: URL(string: "http://localhost:11434/v1/")!)
            .complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0))
        #expect(StubProtocol.requests[0].request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func omitsAuthorizationWithoutKey() async throws {
        StubProtocol.reset([.http(200, Self.ok)])
        _ = try await client(key: nil).complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0, wantsJSON: false))
        #expect(StubProtocol.requests[0].request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try json(0)["response_format"] == nil)
    }

    @Test func sendsImagesAsDataURLParts() async throws {
        StubProtocol.reset([.http(200, Self.ok)])
        let jpeg = Data([0xFF, 0xD8, 0x01])
        _ = try await client().complete(ChatRequest(model: "m", messages: [.user("look", images: [jpeg])], temperature: 0))
        let msgs = try #require(try json(0)["messages"] as? [[String: Any]])
        let parts = try #require(msgs[0]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "look")
        #expect(parts[1]["type"] as? String == "image_url")
        let url = (parts[1]["image_url"] as? [String: String])?["url"]
        #expect(url == "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }

    @Test func retriesWithoutJSONFormatAfter400() async throws {
        StubProtocol.reset([.http(400, #"{"error":{"message":"bad format"}}"#), .http(200, Self.ok), .http(200, Self.ok)])
        let c = client()
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)
        #expect(try await c.complete(req) == "hi")
        #expect(StubProtocol.requests.count == 2)
        #expect(try json(0)["response_format"] != nil)
        #expect(try json(1)["response_format"] == nil)
        _ = try await c.complete(req)
        #expect(StubProtocol.requests.count == 3)
        #expect(try json(2)["response_format"] == nil)
    }

    @Test func sendsOutputTokenCapUnderBothNames() async throws {
        StubProtocol.reset([.http(200, Self.ok)])
        _ = try await client().complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0.2))
        let body = try json(0)
        #expect(body["max_tokens"] as? Int == OpenAIChatClient.defaultMaxOutputTokens)
        #expect(body["max_completion_tokens"] as? Int == OpenAIChatClient.defaultMaxOutputTokens)
    }

    @Test func dropsTemperatureWhenRejectedAndRemembers() async throws {
        let rejected = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported."}}"#
        StubProtocol.reset([.http(400, rejected), .http(200, Self.ok), .http(200, Self.ok)])
        let c = client()
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0.2)
        #expect(try await c.complete(req) == "hi")
        #expect(StubProtocol.requests.count == 2)
        #expect(try json(0)["temperature"] != nil)
        #expect(try json(1)["temperature"] == nil)
        // 다른 필드는 그대로 둔다.
        #expect(try json(1)["response_format"] != nil)
        #expect(try json(1)["max_completion_tokens"] != nil)
        _ = try await c.complete(req)
        #expect(try json(2)["temperature"] == nil)
    }

    @Test func dropsMaxTokensButKeepsMaxCompletionTokens() async throws {
        let rejected = #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#
        StubProtocol.reset([.http(400, rejected), .http(200, Self.ok)])
        _ = try await client().complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0))
        #expect(try json(1)["max_tokens"] == nil)
        #expect(try json(1)["max_completion_tokens"] as? Int == OpenAIChatClient.defaultMaxOutputTokens)
        #expect(try json(1)["temperature"] != nil)
    }

    @Test func dropsSeveralRejectedParametersInTurn() async throws {
        StubProtocol.reset([
            .http(400, #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model."}}"#),
            .http(400, #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.3 with this model."}}"#),
            .http(200, Self.ok),
        ])
        #expect(try await client().complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0.3)) == "hi")
        #expect(StubProtocol.requests.count == 3)
        let last = try json(2)
        #expect(last["max_tokens"] == nil)
        #expect(last["temperature"] == nil)
        #expect(last["max_completion_tokens"] != nil)
        #expect(last["response_format"] != nil)
    }

    @Test func truncatedReplyIsBadReply() async throws {
        let truncated = #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"{\"fixes\":[{\"id\":\"1\""}}]}"#
        StubProtocol.reset([.http(200, truncated)])
        await #expect(throws: LLMError.self) {
            try await client().complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0))
        }
        StubProtocol.reset([.http(200, truncated)])
        do {
            _ = try await client().complete(ChatRequest(model: "m", messages: [.user("x")], temperature: 0))
            Issue.record("오류가 나야 해요")
        } catch let error as LLMError {
            #expect(error.isRetryable)
        }
    }

    @Test func plain400WithoutResponseFormatIsNotRetried() async throws {
        StubProtocol.reset([.http(400, #"{"error":{"message":"nope"}}"#), .http(200, Self.ok)])
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0, wantsJSON: false)
        await #expect(throws: LLMError.http(status: 400, message: "nope")) {
            try await client().complete(req)
        }
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func contextOverflowMapsToContextTooLong() async throws {
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)
        StubProtocol.reset([.http(400, #"{"error":{"code":"context_length_exceeded","message":"too big"}}"#)])
        await #expect(throws: LLMError.contextTooLong) { try await client().complete(req) }
        StubProtocol.reset([.http(400, #"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#)])
        await #expect(throws: LLMError.contextTooLong) { try await client().complete(req) }
        #expect(!LLMError.contextTooLong.isRetryable)
    }

    @Test func mapsErrors() async throws {
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)
        StubProtocol.reset([.http(500, #"{"error":{"message":"boom"}}"#)])
        await #expect(throws: LLMError.http(status: 500, message: "boom")) { try await client().complete(req) }

        StubProtocol.reset([.http(502, String(repeating: "a", count: 500))])
        await #expect(throws: LLMError.http(status: 502, message: String(repeating: "a", count: 300))) {
            try await client().complete(req)
        }

        StubProtocol.reset([.failure(.cannotConnectToHost)])
        await #expect(throws: LLMError.unreachable("http://localhost:11434/v1")) { try await client().complete(req) }

        StubProtocol.reset([.failure(.timedOut)])
        await #expect(throws: LLMError.timedOut) { try await client().complete(req) }

        StubProtocol.reset([.http(200, #"{"choices":[]}"#)])
        await #expect(throws: LLMError.self) { try await client().complete(req) }
    }

    @Test func mapsExtraURLErrors() async throws {
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)
        for code in [URLError.Code.dnsLookupFailed, .cannotLoadFromNetwork, .secureConnectionFailed] {
            StubProtocol.reset([.failure(code)])
            await #expect(throws: LLMError.unreachable("http://localhost:11434/v1")) { try await client().complete(req) }
        }
        for code in [URLError.Code.badServerResponse, .cannotParseResponse] {
            StubProtocol.reset([.failure(code)])
            do {
                _ = try await client().complete(req)
                Issue.record("오류가 나야 해요")
            } catch LLMError.badReply {
            } catch {
                Issue.record("badReply가 아님: \(error)")
            }
        }
    }

    @Test func cancellationSurfacesAsCancellationError() async throws {
        StubProtocol.reset([.hang])
        let c = client()
        let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)
        let task = Task { try await c.complete(req) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("오류가 나야 해요")
        } catch is CancellationError {
        } catch {
            Issue.record("CancellationError가 아님: \(error)")
        }
    }

    @Test func listsModels() async throws {
        StubProtocol.reset([.http(200, #"{"data":[{"id":"b"},{"id":"a"}]}"#)])
        let ids = try await client().models()
        #expect(ids == ["a", "b"])
        let sent = StubProtocol.requests[0].request
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    // MARK: - 스트리밍과 관찰자

    /// 관찰자 호출을 차례로 기록한다.
    final class Recorder: @unchecked Sendable {
        enum Event: Equatable { case phase(ChatPhase), finished(ChatUsage?) }
        private let lock = NSLock()
        private var list: [Event] = []
        var events: [Event] { lock.lock(); defer { lock.unlock() }; return list }
        private func add(_ e: Event) { lock.lock(); list.append(e); lock.unlock() }
        var observer: ChatObserver {
            ChatObserver(phase: { self.add(.phase($0)) }, finished: { self.add(.finished($0)) })
        }
    }

    static func delta(_ text: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return #"data: {"choices":[{"index":0,"delta":{"content":""# + text + #""},"finish_reason":"# + reason + "}]}\n\n"
    }
    static let usageChunk = #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}"# + "\n\n"
    static let done = "data: [DONE]\n\n"
    static let req = ChatRequest(model: "m", messages: [.user("x")], temperature: 0)

    @Test func streamsContentAndUsage() async throws {
        StubProtocol.reset([.sse([
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"생각"},"finish_reason":null}]}"# + "\n\n",
            Self.delta("안녕"), Self.delta(", "), Self.delta("세상", finish: "stop"),
            Self.usageChunk, Self.done,
        ])])
        let rec = Recorder()
        let out = try await client().complete(Self.req, observer: rec.observer)
        #expect(out == "안녕, 세상")
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 12, output: 5))])
    }

    @Test func assemblesContentAcrossChunks() async throws {
        let line = Self.delta("{\\\"fixes\\\":[]}")
        let cut = line.index(line.startIndex, offsetBy: 30)
        StubProtocol.reset([.sse([
            ": keep-alive\n\n",
            Self.delta("앞"),
            String(line[..<cut]), String(line[cut...]),
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"끝\"},", "\"finish_reason\":\"stop\"}]}\n", "\n",
            Self.usageChunk, "data: [DO", "NE]\n\n",
        ])])
        let rec = Recorder()
        let out = try await client().complete(Self.req, observer: rec.observer)
        #expect(out == #"앞{"fixes":[]}끝"#)
        #expect(rec.events.last == .finished(ChatUsage(input: 12, output: 5)))
    }

    @Test func requestsStreamWithUsage() async throws {
        StubProtocol.reset([.sse([Self.delta("hi"), Self.done])])
        _ = try await client().complete(Self.req)
        let body = try json(0)
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test func fallsBackWithoutStream() async throws {
        let okWithUsage = #"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#
        StubProtocol.reset([
            .http(400, #"{"error":{"message":"stream is not supported for this model"}}"#),
            .http(200, okWithUsage), .http(200, okWithUsage),
        ])
        let rec = Recorder()
        let c = client()
        #expect(try await c.complete(Self.req, observer: rec.observer) == "hi")
        #expect(StubProtocol.requests.count == 2)
        #expect(try json(0)["stream"] != nil)
        #expect(try json(1)["stream"] == nil)
        #expect(try json(1)["stream_options"] == nil)
        #expect(try json(1)["response_format"] != nil)
        #expect(rec.events == [
            .phase(.sending),
            .phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 3, output: 1)),
        ])
        // 이후 요청도 스트리밍 없이 보낸다.
        _ = try await c.complete(Self.req)
        #expect(try json(2)["stream"] == nil)
    }

    @Test func dropsOnlyStreamOptionsWhenNamed() async throws {
        StubProtocol.reset([
            .http(400, #"{"error":{"message":"Unrecognized request argument supplied: stream_options"}}"#),
            .sse([Self.delta("hi"), Self.done]),
        ])
        #expect(try await client().complete(Self.req) == "hi")
        #expect(try json(1)["stream"] as? Bool == true)
        #expect(try json(1)["stream_options"] == nil)
    }

    @Test func rejectedFieldMatchesWholeNamesOnly() {
        let all = Set(OpenAIChatClient.OptionalField.allCases)
        #expect(OpenAIChatClient.rejectedField(in: "stream_options is not allowed", sent: all) == .streamOptions)
        #expect(OpenAIChatClient.rejectedField(in: "'stream' is not supported", sent: all) == .stream)
        // 다른 낱말 속의 "stream"은 필드 이름이 아니다.
        #expect(OpenAIChatClient.rejectedField(in: "upstream returned an error", sent: all) == .responseFormat)
        #expect(OpenAIChatClient.rejectedField(in: "streaming failed; 'temperature' is bad", sent: all) == .temperature)
    }

    @Test func missingUsageReported() async throws {
        StubProtocol.reset([.sse([Self.delta("hi", finish: "stop"), Self.done])])
        let rec = Recorder()
        #expect(try await client().complete(Self.req, observer: rec.observer) == "hi")
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(nil)])
    }

    @Test func lengthStillBadReplyAfterFinished() async throws {
        StubProtocol.reset([.sse([Self.delta("{\\\"fixes\\\":[", finish: "length"), Self.usageChunk, Self.done])])
        let rec = Recorder()
        do {
            _ = try await client().complete(Self.req, observer: rec.observer)
            Issue.record("오류가 나야 해요")
        } catch let error as LLMError {
            guard case .badReply = error else { Issue.record("badReply가 아님: \(error)"); return }
            #expect(error.isRetryable)
        }
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 12, output: 5))])
    }

    @Test func emptyStreamIsBadReplyButFinished() async throws {
        StubProtocol.reset([.sse([": keep-alive\n\n"])])
        let rec = Recorder()
        do {
            _ = try await client().complete(Self.req, observer: rec.observer)
            Issue.record("오류가 나야 해요")
        } catch LLMError.badReply {
        } catch {
            Issue.record("badReply가 아님: \(error)")
        }
        #expect(rec.events.last == .finished(nil))
    }

    @Test func emptyDataHeartbeatsAreSkipped() async throws {
        StubProtocol.reset([.sse([
            "data:\n\n", "data: \n\n", Self.delta("안"), "data:\n\n", Self.delta("녕", finish: "stop"),
            "data:  \n\n", Self.usageChunk, Self.done,
        ])])
        let rec = Recorder()
        #expect(try await client().complete(Self.req, observer: rec.observer) == "안녕")
        // receiving은 처음 비지 않은 data에서 한 번만.
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 12, output: 5))])
    }

    @Test func heartbeatsAloneDoNotStartReceiving() async throws {
        StubProtocol.reset([.sse(["data:\n\n", "data: \n\n"])])
        let rec = Recorder()
        await #expect(throws: LLMError.self) { try await client().complete(Self.req, observer: rec.observer) }
        #expect(!rec.events.contains(.phase(.receiving)))
    }

    @Test func streamEndingWithoutDoneOrFinishReasonIsBadReply() async throws {
        StubProtocol.reset([.sse([Self.delta("앞부분"), Self.usageChunk])])
        let rec = Recorder()
        do {
            _ = try await client().complete(Self.req, observer: rec.observer)
            Issue.record("오류가 나야 해요")
        } catch LLMError.badReply(let message) {
            #expect(message == "스트림이 중간에 끊겼어요")
        }
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 12, output: 5))])
    }

    @Test func streamWithFinishReasonButNoDoneIsAccepted() async throws {
        StubProtocol.reset([.sse([Self.delta("끝", finish: "stop")])])
        #expect(try await client().complete(Self.req) == "끝")
    }

    @Test func reasoningOnlyReplyCutByCapReportsTruncation() async throws {
        StubProtocol.reset([.sse([
            #"data: {"choices":[{"index":0,"delta":{"reasoning_content":"생각"},"finish_reason":null}]}"# + "\n\n",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"# + "\n\n",
            Self.done,
        ])])
        do {
            _ = try await client().complete(Self.req)
            Issue.record("오류가 나야 해요")
        } catch LLMError.badReply(let message) {
            #expect(message.contains("잘렸어요"))
        }
    }

    @Test func zeroUsageErrorWithoutUsageIsNotFinished() async throws {
        StubProtocol.reset([.http(429, #"{"error":{"message":"slow down"}}"#)])
        let rec = Recorder()
        await #expect(throws: LLMError.http(status: 429, message: "slow down")) {
            try await client().complete(Self.req, observer: rec.observer)
        }
        #expect(rec.events == [.phase(.sending)])
    }

    @Test func errorResponseReportsUsageFromBody() async throws {
        StubProtocol.reset([.http(500, #"{"error":{"message":"boom"},"usage":{"prompt_tokens":7,"completion_tokens":0}}"#)])
        let rec = Recorder()
        await #expect(throws: LLMError.http(status: 500, message: "boom")) {
            try await client().complete(Self.req, observer: rec.observer)
        }
        #expect(rec.events == [.phase(.sending), .finished(ChatUsage(input: 7, output: 0))])
    }

    @Test func cancellationDoesNotFinish() async throws {
        StubProtocol.reset([.hang])
        let c = client()
        let rec = Recorder()
        let task = Task { try await c.complete(Self.req, observer: rec.observer) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("오류가 나야 해요")
        } catch is CancellationError {
        } catch {
            Issue.record("CancellationError가 아님: \(error)")
        }
        #expect(rec.events == [.phase(.sending)])
    }

    @Test func connectionFailureDoesNotFinish() async throws {
        StubProtocol.reset([.failure(.cannotConnectToHost)])
        let rec = Recorder()
        await #expect(throws: LLMError.unreachable("http://localhost:11434/v1")) {
            try await client().complete(Self.req, observer: rec.observer)
        }
        #expect(rec.events == [.phase(.sending)])
    }

    @Test func nonStreamReplyToStreamRequestIsAccepted() async throws {
        StubProtocol.reset([.http(200, #"{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":4,"completion_tokens":2}}"#)])
        let rec = Recorder()
        #expect(try await client().complete(Self.req, observer: rec.observer) == "hi")
        #expect(try json(0)["stream"] as? Bool == true)
        #expect(rec.events == [.phase(.sending), .phase(.receiving), .finished(ChatUsage(input: 4, output: 2))])
    }

    static let liveEnabled = ProcessInfo.processInfo.environment["JAMAK_LLM_TESTS"] == "1"

    @Test(.enabled(if: OpenAIChatClientTests.liveEnabled))
    func liveRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(string: env["JAMAK_LLM_BASE_URL"] ?? "http://localhost:11434/v1")!
        let model = try #require(env["JAMAK_LLM_MODEL"])
        let c = OpenAIChatClient(baseURL: base, apiKey: env["JAMAK_LLM_API_KEY"])
        let out = try await c.complete(ChatRequest(
            model: model,
            messages: [.user(#"Reply with exactly this JSON and nothing else: {"ok":true}"#)],
            temperature: 0))
        let obj = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(obj["ok"] as? Bool == true)
    }
}
