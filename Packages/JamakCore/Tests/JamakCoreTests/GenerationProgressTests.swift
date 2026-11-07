import Testing
import Foundation
@testable import JamakCore

@Suite struct GenerationProgressTests {
    @Test func projectJsonWithoutGenerationDecodes() throws {
        let json = """
        {"version":3,"originalLanguage":"ja","videoBookmark":"AAEC","videoPath":"/v.mp4","videoFileSize":10,
         "videoDurationMs":1000}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.setGeneration == nil)
    }

    @Test func progressRoundTrips() throws {
        var state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        var g = GenerationProgress()
        g.audioExtracted = true
        g.framesCapturedUpTo = 42
        let set = UUID()
        state.setGeneration = [set: g]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(ProjectState.self, from: data)
        #expect(back.setGeneration == [set: g])
        #expect(GenerationProgress().framesCapturedUpTo == -1)
    }

    @Test func isCompleteNeedsAllStages() {
        var g = GenerationProgress()
        #expect(!g.isComplete)
        g.audioExtracted = true; g.transcribed = true; g.soundsClassified = true
        #expect(!g.isComplete)
        g.textRecognized = true
        // 분석·교정은 생성 단계가 아니다.
        #expect(g.isComplete)
        g.soundsClassified = false
        #expect(!g.isComplete)
    }

    @Test func oldGenerationJsonDecodesWithNewFieldsFalse() throws {
        let json = """
        {"audioExtracted":true,"transcribed":true,"soundsClassified":true,"framesCapturedUpTo":9,"textRecognized":true}
        """
        let g = try JSONDecoder().decode(GenerationProgress.self, from: Data(json.utf8))
        #expect(!g.analyzed && !g.corrected)
        #expect(g.isComplete)
        #expect(g.framesCapturedUpTo == 9)
        // 키가 하나도 없어도 기본값으로 읽는다.
        let empty = try JSONDecoder().decode(GenerationProgress.self, from: Data("{}".utf8))
        #expect(empty == GenerationProgress())
    }

    @Test func newFieldsRoundTrip() throws {
        var g = GenerationProgress()
        g.analyzed = true
        let back = try JSONDecoder().decode(GenerationProgress.self, from: JSONEncoder().encode(g))
        #expect(back == g && back.analyzed && !back.corrected)
    }

    @Test func translationProgressRoundTrips() throws {
        var t = TranslationProgress(sourceLanguage: "en")
        #expect(!t.isComplete)
        t.glossaryDone = true
        #expect(!t.isComplete)
        t.translated = true
        #expect(t.isComplete)
        var state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        let key = ProjectState.translationKey(set: UUID(), language: .ko)
        state.setTranslations = [key: t]
        let back = try JSONDecoder().decode(ProjectState.self, from: JSONEncoder().encode(state))
        #expect(back.setTranslations == [key: t])
    }

    @Test func stateWithoutTranslationsDecodes() throws {
        let id = UUID()
        let json = """
        {"version":3,"originalLanguage":"ja","videoBookmark":"AAEC","videoPath":"/v.mp4","videoFileSize":10,
         "videoDurationMs":1000,"setGeneration":{"\(id.uuidString)":{"audioExtracted":true}}}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.setTranslations == nil)
        #expect(state.setGeneration?[id]?.audioExtracted == true)
    }

    @Test func optionsRoundTrip() throws {
        var g = GenerationProgress(options: GenerationOptions(sounds: false))
        g.transcribed = true
        let back = try JSONDecoder().decode(GenerationProgress.self, from: JSONEncoder().encode(g))
        #expect(back == g)
        #expect(back.options?.sounds == false && back.options?.transcribe == true)
    }

    @Test func translationOptionsRoundTrip() throws {
        var t = TranslationProgress(sourceLanguage: "ja", fillEmptyOnly: true)
        t.glossaryDone = true
        #expect(!t.isComplete)
        t.translated = true
        #expect(t.isComplete)
        let back = try JSONDecoder().decode(TranslationProgress.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }

    @Test func stateSubscriptsReadAndWritePerSetProgress() {
        var state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        let a = UUID(), b = UUID()
        #expect(state[generation: a] == nil)
        state[generation: a] = GenerationProgress()
        state[generation: a]?.transcribed = true
        #expect(state[generation: a]?.transcribed == true && state[generation: b] == nil)
        state[translation: a, .ko] = TranslationProgress(sourceLanguage: "ja")
        state[translation: a, .ko]?.translated = true
        #expect(state.setTranslations?[ProjectState.translationKey(set: a, language: .ko)]?.translated == true)
        #expect(state[translation: a, .en] == nil && state[translation: b, .ko] == nil)
        state[generation: a] = nil
        #expect(state.setGeneration?.isEmpty == true)
    }

    @Test func resetUnfinishedGlossariesInEverySetKeepsFinished() {
        var state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        let a = UUID(), b = UUID()
        var partial = TranslationProgress(sourceLanguage: "ja")
        partial.glossaryDone = true
        var done = partial
        done.translated = true
        state[translation: a, .ko] = partial
        state[translation: a, .en] = done
        state[translation: b, .ko] = partial
        state[translation: b, .en] = done
        state.resetUnfinishedGlossaries()
        for set in [a, b] {
            #expect(state[translation: set, .ko]?.glossaryDone == false)
            #expect(state[translation: set, .ko]?.translated == false)
            #expect(state[translation: set, .en] == done)
        }
    }

    @Test func clearTranslationsRemovesOnlyThatSet() {
        var state = ProjectState(originalLanguage: .ja, videoBookmark: Data([1]), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 1000)
        let a = UUID(), b = UUID()
        state[translation: a, .ko] = TranslationProgress(sourceLanguage: "ja")
        state[translation: a, .en] = TranslationProgress(sourceLanguage: "ja")
        state[translation: b, .ko] = TranslationProgress(sourceLanguage: "ja")
        state.clearTranslations(set: a)
        #expect(state[translation: a, .ko] == nil && state[translation: a, .en] == nil)
        #expect(state[translation: b, .ko] != nil)
    }
}
