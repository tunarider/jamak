import Foundation
import Testing
@testable import JamakCore

struct JSONReplyTests {
    struct A: Decodable, Equatable { var a: Int }

    @Test func decodesFencedJSON() throws {
        #expect(try JSONReply.decode(A.self, from: "```json\n{\"a\":1}\n```") == A(a: 1))
    }

    @Test func decodesJSONAfterProse() throws {
        #expect(try JSONReply.decode(A.self, from: "네, 결과입니다: {\"a\":1} 끝") == A(a: 1))
    }

    @Test func decodesBracesInsideStrings() throws {
        struct S: Decodable, Equatable { var s: String }
        #expect(try JSONReply.decode(S.self, from: "x {\"s\":\"}{\"} y") == S(s: "}{"))
    }

    @Test func brokenJSONIsBadReply() {
        #expect(throws: LLMError.self) { try JSONReply.decode(A.self, from: "{\"a\":") }
        #expect(throws: LLMError.self) { try JSONReply.decode(A.self, from: "없어요") }
        #expect(throws: LLMError.self) { try JSONReply.decode(A.self, from: "{\"b\":1}") }
    }

    @Test func stripsKindMarkupFromReply() {
        #expect(JSONReply.cleanText("[銃声]", kind: .sound) == "銃声")
        #expect(JSONReply.cleanText("［銃声］", kind: .sound) == "銃声")
        #expect(JSONReply.cleanText("{\\an8}「出口」", kind: .screen) == "出口")
        #expect(JSONReply.cleanText("「出口」", kind: .screen) == "出口")
        #expect(JSONReply.cleanText("{\\an8}出口", kind: .screen) == "出口")
        #expect(JSONReply.cleanText("「待て」と言った", kind: .speech) == "「待て」と言った")
        #expect(JSONReply.cleanText("  待て \n", kind: .speech) == "待て")
        #expect(JSONReply.cleanText("  [銃声] ", kind: .sound) == "銃声")
        #expect(JSONReply.cleanText("[]", kind: .sound) == "")
    }

    @Test func retryability() {
        #expect(LLMError.http(status: 503, message: "").isRetryable)
        #expect(!LLMError.http(status: 401, message: "").isRetryable)
        #expect(LLMError.timedOut.isRetryable)
        #expect(LLMError.badReply("").isRetryable)
        #expect(!LLMError.unreachable("u").isRetryable)
    }

    @Test func promptsFillPlaceholders() {
        #expect(Prompts.fill("a {{x}} b", ["x": "1"]) == "a 1 b")
        #expect(Prompts.fill("{{unknown}} {{x}} {{", ["x": "1"]) == "{{unknown}} 1 {{")
    }

    @Test func promptsFillIsSinglePass() {
        // 메모 속 {{lines}}는 줄 목록으로 바뀌지 않는다(값의 순서와 상관없이).
        let template = "메모:\n{{memos}}\n노트:\n{{notes}}\n줄:\n{{lines}}"
        let values = ["memos": "장면 {{lines}} 메모", "notes": "{{memos}}", "lines": "L1\nL2"]
        #expect(Prompts.fill(template, values) == "메모:\n장면 {{lines}} 메모\n노트:\n{{memos}}\n줄:\nL1\nL2")
    }

    @Test func promptsLoadFromBundle() throws {
        #expect(!(try Prompts.text("README")).isEmpty)
        #expect(throws: LLMError.self) { try Prompts.text("없는이름") }
    }
}
