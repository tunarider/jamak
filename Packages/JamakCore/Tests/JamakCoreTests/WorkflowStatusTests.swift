import Testing
import Foundation
@testable import JamakCore

struct WorkflowStatusTests {
    let setA = UUID(), setB = UUID(), cueA = UUID()
    func key(_ set: UUID, _ lang: Language) -> String { ProjectState.translationKey(set: set, language: lang) }
    func state(duration: Int = 10_000, generation: GenerationProgress? = nil,
               generations: [UUID: GenerationProgress]? = nil,
               translations: [String: TranslationProgress]? = nil,
               tickets: [Ticket] = []) -> ProjectState {
        ProjectState(originalLanguage: .ja, videoBookmark: Data(), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: duration,
                     tickets: tickets.isEmpty ? nil : TicketBook(tickets: tickets),
                     setGeneration: generations ?? generation.map { [setA: $0] },
                     setTranslations: translations)
    }
    func media(frames: Int = 9) -> GenerationProgress {
        var g = GenerationProgress()
        g.audioExtracted = true; g.transcribed = true; g.soundsClassified = true
        g.framesCapturedUpTo = frames; g.textRecognized = true
        return g
    }

    @Test func freshStateIsAllNone() {
        let s = WorkflowStatus(state: state(), hasSourceSet: false)
        #expect(s.transcribe == .none && s.analyze == .none && s.correct == .none)
        #expect(s.translate == .none)
        #expect(s.stoppedStepName == nil)
    }

    @Test func importedSourceSetCountsAsTranscribed() {
        let s = WorkflowStatus(state: state(), hasSourceSet: true)
        #expect(s.transcribe == .done)
        #expect(WorkflowStatus(state: state(generation: GenerationProgress()), hasSourceSet: true).transcribe == .done)
    }

    @Test func partialMediaIsPartial() {
        var g = GenerationProgress(); g.audioExtracted = true
        #expect(WorkflowStatus(state: state(generation: g), hasSourceSet: false).transcribe == .partial)
        // 프레임이 마지막 초까지 못 갔다
        #expect(WorkflowStatus(state: state(generation: media(frames: 5)), hasSourceSet: false).transcribe == .partial)
    }

    @Test func stage2CompleteIsTranscribeDoneOthersNone() {
        let s = WorkflowStatus(state: state(generation: media()), hasSourceSet: false)
        #expect(s.transcribe == .done && s.analyze == .none && s.correct == .none)
        var g = media(); g.analyzed = true
        let s2 = WorkflowStatus(state: state(generation: g), hasSourceSet: false)
        #expect(s2.analyze == .done && s2.correct == .none)
    }

    @Test func translationStates() {
        var done = TranslationProgress(sourceLanguage: "ja")
        done.glossaryDone = true; done.translated = true
        var part = TranslationProgress(sourceLanguage: "ja"); part.glossaryDone = true
        let none = TranslationProgress(sourceLanguage: "ja")
        let s = WorkflowStatus(state: state(translations: [key(setA, .ko): done, key(setA, .en): part,
                                                            key(setA, .ja): none]), hasSourceSet: false)
        // 언어마다 나누지 않고 가장 앞선 번역을 따른다.
        #expect(s.translate == .done)
        #expect(WorkflowStatus(state: state(translations: [key(setA, .en): part, key(setA, .ja): none]), hasSourceSet: false).translate
                    == .partial)
        #expect(WorkflowStatus(state: state(translations: [key(setA, .ja): none]), hasSourceSet: false).translate == .none)
    }

    /// 고른 할 일만 따진다: 받아쓰기만 한 생성은 받아쓰기 끝, 분석·교정은 안 함이고 멈춘 것이 아니다.
    @Test func mediaFollowsChosenTasks() {
        var g = GenerationProgress(options: GenerationOptions(sounds: false, screenText: false))
        g.audioExtracted = true; g.transcribed = true
        let s = WorkflowStatus(state: state(generation: g), hasSourceSet: false)
        #expect(s.transcribe == .done && s.analyze == .none)
        #expect(s.stoppedStepName == nil)
        #expect(!ProjectFilter.resumable.includes(summary(state(generation: g))))
        // 미디어 할 일이 없는 생성(분석과 교정만)은 받아쓰기 상태를 바꾸지 않는다.
        var llm = GenerationProgress(options: GenerationOptions(transcribe: false, sounds: false,
                                                               screenText: false))
        llm.analyzed = true
        #expect(WorkflowStatus(state: state(generation: llm), hasSourceSet: false).transcribe == .none)
        #expect(WorkflowStatus(state: state(generation: llm), hasSourceSet: true).transcribe == .done)
        #expect(WorkflowStatus(state: state(generation: llm), hasSourceSet: false).analyze == .done)
    }

    @Test func stoppedStepNameIsFirstPartial() {
        var g = media(); g.textRecognized = false
        #expect(WorkflowStatus(state: state(generation: g), hasSourceSet: false).stoppedStepName == "받아쓰기")
        var part = TranslationProgress(sourceLanguage: "ja"); part.translated = true
        #expect(WorkflowStatus(state: state(generation: media(), translations: [key(setA, .ko): part]), hasSourceSet: false).stoppedStepName == "번역")
        #expect(WorkflowStatus(state: state(generation: media()), hasSourceSet: false).stoppedStepName == nil)
    }

    /// 자막셋 setA(조각 하나)만 있는 프로젝트의 요약.
    func summary(_ state: ProjectState) -> ProjectSummary {
        let set = CueSet(id: setA, name: "기본", languages: [.ja],
                         cues: [Cue(id: cueA, start: 0, end: 1, kind: .speech, texts: [.ja: "あ"])])
        return ProjectSummary(folder: URL(fileURLWithPath: "/p"), state: state, subtitles: SubtitleData(sets: [set]))
    }

    @Test func filters() {
        func ticket(_ level: Ticket.Level, set: UUID? = nil) -> Ticket {
            Ticket(setID: set ?? setA, origin: .source, language: .ja, level: level, reason: "",
                   changes: [TicketChange(cueID: cueA, before: "あ", after: "い")])
        }
        func includes(_ f: ProjectFilter, _ st: ProjectState) -> Bool { f.includes(summary(st)) }
        #expect(includes(.recent, state()))
        #expect(!includes(.needsReview, state()))
        // 고침도 의심도 처리를 기다리는 티켓이다.
        #expect(includes(.needsReview, state(tickets: [ticket(.fix)])))
        #expect(includes(.needsReview, state(tickets: [ticket(.suspect)])))
        // 없는 자막셋의 티켓은 세지 않는다(카드의 수와 같다).
        #expect(!includes(.needsReview, state(tickets: [ticket(.suspect, set: setB)])))

        #expect(!includes(.resumable, state()))
        var stopped = media(); stopped.textRecognized = false
        #expect(includes(.resumable, state(generation: stopped)))   // 화면 글자 읽기 전
        // 분석·교정은 생성 단계가 아니다: 미디어 단계를 마친 생성은 이어 할 작업이 아니다.
        #expect(!includes(.resumable, state(generation: media())))
        var full = media(); full.analyzed = true; full.corrected = true
        #expect(!includes(.resumable, state(generation: full)))
        var part = TranslationProgress(sourceLanguage: "ja"); part.translated = true
        #expect(includes(.resumable, state(generation: full, translations: [key(setA, .ko): part])))
        var done = TranslationProgress(sourceLanguage: "ja")
        done.glossaryDone = true; done.translated = true
        #expect(!includes(.resumable, state(generation: full, translations: [key(setA, .ko): done])))
        // 지운 자막셋(setB)의 멈춘 진행은 이어 할 작업이 아니다.
        #expect(!includes(.resumable, state(generations: [setA: full, setB: stopped])))
        #expect(!includes(.resumable, state(generation: full, translations: [key(setB, .ko): part])))

        // 열 수 없는 폴더는 "최근 프로젝트"에만 보인다.
        for format in [ProjectSummary.Format.legacy, .newer, .corrupt] {
            let u = ProjectSummary.unopenable(folder: URL(fileURLWithPath: "/u"), format: format)
            #expect(ProjectFilter.allCases.filter { $0.includes(u) } == [.recent])
        }
    }

    @Test func aggregatesOverSetsUsingFurthestSet() {
        var started = GenerationProgress(); started.audioExtracted = true
        var full = media(); full.analyzed = true
        // 한 자막셋이라도 끝났으면 done.
        let s = WorkflowStatus(state: state(generations: [setA: started, setB: full]), hasSourceSet: false)
        #expect(s.transcribe == .done && s.analyze == .done && s.correct == .none)
        // 끝난 것이 없으면 시작한 것이 있을 때 partial.
        #expect(WorkflowStatus(state: state(generations: [setA: GenerationProgress(), setB: started]), hasSourceSet: false).transcribe == .partial)

        var done = TranslationProgress(sourceLanguage: "ja")
        done.glossaryDone = true; done.translated = true
        var part = TranslationProgress(sourceLanguage: "ja"); part.glossaryDone = true
        let t = WorkflowStatus(state: state(translations: [key(setA, .ko): part, key(setB, .ko): done,
                                                           key(setB, .en): part]), hasSourceSet: false)
        #expect(t.translate == .done)
        // 어느 자막셋이든 미완료면 이어 하기(요약은 지금 있는 자막셋만 센다: 여기서는 setA).
        #expect(ProjectFilter.resumable.includes(summary(state(generations: [setA: started, setB: full]))))
        #expect(ProjectFilter.resumable.includes(summary(state(translations: [key(setA, .ko): part, key(setB, .ko): done]))))
    }

    @Test func posterSecond() {
        #expect(PosterFrame.second(durationMs: 7_122_000) == 712)
        #expect(PosterFrame.second(durationMs: 0) == 0)
    }
}
