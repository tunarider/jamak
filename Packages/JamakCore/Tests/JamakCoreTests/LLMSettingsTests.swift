import Foundation
import Testing
@testable import JamakCore

@Suite struct LLMSettingsTests {
    @Test func decodesDefaultsWhenMissingOrCorrupt() {
        #expect(LLMSettings.decode(nil) == LLMSettings())
        #expect(LLMSettings.decode(Data("not json".utf8)) == LLMSettings())
        #expect(LLMSettings.decode(Data("{}".utf8)) == LLMSettings())
        #expect(LLMSettings().concurrency == 2)
    }

    @Test func roundTrips() throws {
        var s = LLMSettings()
        let p = LLMProvider.make(.ollama)
        s.providers = [p]
        s.textModel = ModelChoice(providerID: p.id, model: "qwen")
        s.concurrency = 4
        #expect(LLMSettings.decode(try JSONEncoder().encode(s)) == s)
    }

    @Test func concurrencyClampedToRange() {
        func decoded(_ n: Int) -> Int { LLMSettings.decode(Data(#"{"concurrency":\#(n)}"#.utf8)).concurrency }
        #expect(decoded(0) == 1)
        #expect(decoded(20) == 8)
        #expect(decoded(5) == 5)
        var s = LLMSettings()
        s.concurrency = 99
        #expect(s.clampedConcurrency == 8)
    }

    @Test func textReadyNeedsExistingProvider() {
        var s = LLMSettings()
        #expect(!s.isTextReady)
        let p = LLMProvider.make(.lmStudio)
        s.textModel = ModelChoice(providerID: p.id, model: "m")
        #expect(!s.isTextReady)          // 프로바이더가 목록에 없다
        s.providers = [p]
        #expect(s.isTextReady)
    }

    @Test func removingProviderClearsModelChoices() {
        var s = LLMSettings()
        let a = LLMProvider.make(.ollama), b = LLMProvider.make(.openAI)
        s.providers = [a, b]
        s.textModel = ModelChoice(providerID: a.id, model: "x")
        s.visionModel = ModelChoice(providerID: b.id, model: "y")
        s.removeProvider(a.id)
        #expect(s.providers == [b])
        #expect(s.textModel == nil)
        #expect(s.visionModel?.providerID == b.id)
    }

    @Test func presetsFillBaseURL() {
        #expect(LLMProvider.make(.ollama).baseURL == "http://localhost:11434/v1")
        #expect(LLMProvider.make(.lmStudio).baseURL == "http://localhost:1234/v1")
        #expect(LLMProvider.make(.openAI).baseURL == "https://api.openai.com/v1")
        #expect(LLMProvider.make(.custom).baseURL.isEmpty)
    }
}

@Suite struct LLMErrorDescriptionTests {
    @Test func koreanDescriptionCoversEveryCase() {
        #expect(LLMError.unreachable("http://localhost:11434/v1").koreanDescription == "서버에 연결할 수 없어요 (http://localhost:11434/v1)")
        #expect(LLMError.http(status: 404, message: "model not found").koreanDescription == "HTTP 404: model not found")
        #expect(LLMError.timedOut.koreanDescription == "시간이 초과됐어요")
        #expect(LLMError.badReply("모델 목록을 읽을 수 없어요").koreanDescription == "서버 응답을 이해할 수 없어요: 모델 목록을 읽을 수 없어요")
    }
}
