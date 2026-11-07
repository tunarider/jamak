import Testing
import Foundation
@testable import JamakCore

@Suite struct TokenUsageTests {
    @Test func recordAddsAndRemembersModel() {
        var book = TokenUsageBook()
        book.record(.analyze, model: "a", usage: ChatUsage(input: 10, output: 5))
        book.record(.analyze, model: "b", usage: ChatUsage(input: 3, output: 2))
        let u = book.usage(.analyze)
        #expect(u.input == 13 && u.output == 7 && u.requests == 2)
        #expect(u.total == 20)
        #expect(u.lastModel == "b")
        #expect(!u.missingUsage)
    }

    @Test func missingUsageCountsRequestOnly() {
        var book = TokenUsageBook()
        book.record(.translate, model: "m", usage: ChatUsage(input: 4, output: 1))
        book.record(.translate, model: "m2", usage: nil)
        let u = book.usage(.translate)
        #expect(u.input == 4 && u.output == 1 && u.requests == 2)
        #expect(u.missingUsage)
        #expect(u.lastModel == "m2")
        #expect(book.usage(.review) == TaskUsage())
    }

    @Test func totalSumsAllTasks() {
        var book = TokenUsageBook()
        book.record(.analyze, model: "a", usage: ChatUsage(input: 10, output: 5))
        book.record(.correct, model: "a", usage: ChatUsage(input: 1, output: 2))
        #expect(book.total.missingUsage == false)
        book.record(.verify, model: "a", usage: nil)
        let t = book.total
        #expect(t.input == 11 && t.output == 7 && t.requests == 3)
        #expect(t.missingUsage)
    }

    @Test func bookRoundTripsWithStringKeys() throws {
        var book = TokenUsageBook()
        book.record(.analyze, model: "a", usage: ChatUsage(input: 10, output: 5))
        book.record(.review, model: "r", usage: nil)
        let data = try JSONEncoder().encode(book)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tasks = try #require(json["tasks"] as? [String: Any])
        #expect(Set(tasks.keys) == ["analyze", "review"])
        #expect(try JSONDecoder().decode(TokenUsageBook.self, from: data) == book)
    }

    @Test func decodingSkipsUnknownTasksAndFillsMissingFields() throws {
        let json = #"{"tasks":{"analyze":{"input":7},"future":{"input":1,"output":1,"requests":1}}}"#
        let book = try JSONDecoder().decode(TokenUsageBook.self, from: Data(json.utf8))
        #expect(book.tasks.count == 1)
        #expect(book.usage(.analyze) == TaskUsage(input: 7))
    }

    @Test func oldProjectStateDecodesWithoutTokenUsage() throws {
        let state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        #expect(state.tokenUsage == nil)
        let data = try JSONEncoder().encode(state)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "tokenUsage")
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try JSONDecoder().decode(ProjectState.self, from: old).tokenUsage == nil)

        var withUsage = state
        var book = TokenUsageBook()
        book.record(.glossary, model: "m", usage: ChatUsage(input: 1, output: 1))
        withUsage.tokenUsage = book
        let round = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(withUsage))
        #expect(round.tokenUsage == book)
    }

    @Test func taskTitlesInSpecOrder() {
        #expect(LLMTask.allCases.map(\.title) == ["분석", "원문 검토", "화면 확인", "용어집", "번역", "번역 검토"])
    }
}
