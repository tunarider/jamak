import Testing
import Foundation
@testable import JamakCore

/// AI 결과를 자막셋에 되쓰는 도우미(설계 8절, 11.1·11.4): 생성 단계, 번역, 검토.
@MainActor
@Suite struct CueWriteTests {
    /// 자막셋(ja 기본 + ko + en), 조각 셋: a(화면, 0–1000), b(음성, 2000–3000), c(소리, 5000–6000).
    struct Fixture {
        let set: CueSet
        let a: Cue, b: Cue, c: Cue
    }

    func make() -> Fixture {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        try! s.addLanguage(.en)
        let a = Cue(start: 0, end: 1000, kind: .screen, texts: [.ja: "第三埠頭", .en: "Pier 3"])
        let b = Cue(start: 2000, end: 3000, kind: .speech, texts: [.ja: "どこだ", .ko: "어디야"])
        let c = Cue(start: 5000, end: 6000, kind: .sound, texts: [.ja: "銃声"])
        s.cues = [a, b, c]
        return Fixture(set: s, a: a, b: b, c: c)
    }

    func editor(_ f: Fixture, tickets: [Ticket] = []) -> SubtitleDataEditor {
        SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: tickets))
    }

    func suspect(_ set: UUID, _ cue: UUID, _ language: Language, before: String = "x") -> Ticket {
        Ticket(setID: set, origin: .translation, language: language, level: .suspect, reason: "",
               changes: [TicketChange(cueID: cue, before: before, after: "")])
    }

    func clip(_ start: Int, _ end: Int, _ kind: SubtitleKind = .speech, _ text: String = "x") -> SubtitleClip {
        SubtitleClip(start: start, end: end, kind: kind, text: text)
    }

    // MARK: 번역

    @Test func translationWritesOnlyTargetCells() {
        let f = make()
        let ed = editor(f)
        // 빈 칸만: ko가 빈 a, c만 번역한다(b는 손으로 채운 칸).
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: nil, fillEmptyOnly: true)
        #expect(sources.map(\.id) == [f.a.id, f.c.id])
        #expect(sources.map(\.text) == ["第三埠頭", "銃声"])
        let write = TranslationWrite.write([f.a.id: "제3부두", f.c.id: "총성", f.b.id: "무시"], sources: sources,
                                           in: f.set, target: .ko, fillEmptyOnly: true)
        #expect(write.removing.isEmpty && write.adding.isEmpty)
        #expect(ed.apply(write, to: f.set.id, actionName: "번역"))
        let s = ed.set(f.set.id)!
        #expect(s.cues.map(\.id) == [f.a.id, f.b.id, f.c.id])
        for (old, new) in zip(f.set.cues, s.cues) {
            // 시간, 종류, 다른 언어 칸은 그대로다.
            #expect(new.start == old.start && new.end == old.end && new.kind == old.kind)
            #expect(new.text(.ja) == old.text(.ja) && new.text(.en) == old.text(.en))
        }
        #expect(s.cues.map { $0.text(.ko) } == ["제3부두", "어디야", "총성"])
        #expect(ed.tickets.tickets.isEmpty)
    }

    @Test func retranslationReplacesCellsWithoutTickets() {
        let f = make()
        let ed = editor(f)
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: nil, fillEmptyOnly: false)
        #expect(sources.map(\.id) == [f.a.id, f.b.id, f.c.id])
        // 응답을 받지 못한 c는 칸을 그대로 둔다.
        let write = TranslationWrite.write([f.a.id: "제3부두", f.b.id: "어디냐"], sources: sources, in: f.set,
                                           target: .ko, fillEmptyOnly: false)
        ed.apply(write, to: f.set.id, actionName: "번역")
        #expect(ed.set(f.set.id)!.cues.map { $0.text(.ko) } == ["제3부두", "어디냐", ""])
        #expect(write.tickets.isEmpty && ed.tickets.tickets.isEmpty)
    }

    @Test func translationScopeAndMissingTargetLanguage() {
        var f = make()
        var s = f.set
        try! s.removeLanguage(.en, original: .ja)
        f = Fixture(set: s, a: f.a, b: f.b, c: f.c)
        let ed = editor(f)
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .en, scope: [f.b.id], fillEmptyOnly: true)
        #expect(sources.map(\.id) == [f.b.id])
        let write = TranslationWrite.write([f.b.id: "Where"], sources: sources, in: f.set, target: .en,
                                           fillEmptyOnly: true)
        // 대상 언어가 없으면 같은 단계에서 더한다.
        #expect(ed.apply(write, to: f.set.id, actionName: "이 조각 번역"))
        #expect(ed.set(f.set.id)!.languages == [.ja, .ko, .en])
        #expect(ed.set(f.set.id)!.cues.map { $0.text(.en) } == ["", "Where", ""])
        ed.undoManager.undo()
        #expect(ed.set(f.set.id)!.languages == [.ja, .ko])
    }

    /// AI가 고친 칸을 사람이 고치면 그 티켓이 닫히고, 다음 고침의 원래 문장은 사람이 쓴 문장이다.
    @Test func laterFixAfterUserEditRevertsToUserText() {
        let f = make()
        let ed = editor(f)
        func fix(_ from: String, _ to: String) -> CueWrite {
            CueWrite(language: .ko, texts: [f.b.id: to],
                     tickets: [Ticket(setID: f.set.id, origin: .translation, language: .ko, level: .fix, reason: "교정",
                                      changes: [TicketChange(cueID: f.b.id, before: from, after: to)])])
        }
        ed.apply(fix("어디야", "어디냐"), to: f.set.id, actionName: "교정")
        ed.setText("어디 있어", cue: f.b.id, language: .ko, in: f.set.id, actionName: "문장 수정")
        #expect(ed.tickets.tickets.isEmpty)
        ed.apply(fix("어디 있어", "어디 있니"), to: f.set.id, actionName: "교정")
        let tickets = ed.tickets.tickets
        #expect(tickets.count == 1)
        #expect(tickets.first?.changes.first?.before == "어디 있어")
        ed.reject(ticket: tickets.first!.id)
        #expect(ed.set(f.set.id)!.cues.first { $0.id == f.b.id }?.text(.ko) == "어디 있어")
    }

    @Test func applyOpensOnlyValidTicketsForThisSet() {
        let f = make()
        let ed = editor(f)
        let write = CueWrite(language: .ko, tickets: [
            suspect(f.set.id, f.b.id, .ko),
            suspect(UUID(), f.b.id, .ko),
            suspect(f.set.id, f.b.id, .ko),         // 같은 칸: 먼저 나온 것을 쓴다
            suspect(f.set.id, UUID(), .ko),
        ])
        ed.apply(write, to: f.set.id, actionName: "검토")
        #expect(ed.tickets.tickets.map(\.id) == [write.tickets[0].id])
    }

    @Test func applyClosesTicketsOfRewrittenCells() {
        let f = make()
        let ed = editor(f, tickets: [suspect(f.set.id, f.b.id, .ko, before: "어디야"),
                                     suspect(f.set.id, f.b.id, .ja, before: "どこだ")])
        ed.apply(CueWrite(language: .ko, texts: [f.b.id: "어디냐"]), to: f.set.id, actionName: "번역")
        #expect(ed.tickets.tickets.map(\.language) == [.ja])
    }

    // MARK: 생성

    /// 음성만 다시 만들면 음성 조각(과 그 티켓)만 지우고 화면·소리 조각과 장면 메모는 그대로 둔다.
    @Test func regenerateSpeechKeepsOtherKindsAndMemos() {
        var f = make()
        var s0 = f.set
        let memo = SceneMemo(start: 0, end: 4000, text: "부두 장면")
        s0.memos = [memo]
        f = Fixture(set: s0, a: f.a, b: f.b, c: f.c)
        let ed = editor(f, tickets: [suspect(f.set.id, f.b.id, .ko), suspect(f.set.id, f.a.id, .en)])
        let generated = [clip(500, 1500, .speech, "新しい")]
        let write = GenerationWrite.stage(generated, original: .ja, in: f.set, replacingKinds: [.speech])
        #expect(write.removing == [f.b.id])
        #expect(ed.apply(write, to: f.set.id, actionName: "자동 생성"))
        let s = ed.set(f.set.id)!
        #expect(Set(s.cues.map(\.id)) == [f.a.id, f.c.id, generated[0].id])
        #expect(s.cues.first { $0.id == f.a.id } == f.a)
        #expect(s.cues.first { $0.id == f.c.id } == f.c)
        #expect(s.cues.first { $0.id == generated[0].id }?.texts == [.ja: "新しい"])
        // 지운 조각의 티켓만 사라진다.
        #expect(ed.tickets.tickets.map(\.changes[0].cueID) == [f.a.id])
        #expect(s.memos == [memo])
        #expect(s.languages == [.ja, .ko, .en])
    }

    /// 고른 트랙을 모두 고르면 그 종류를 모두 지운다. 고르지 않은 종류는 남는다.
    @Test func regenerateRemovesOnlyChosenKinds() {
        let f = make()
        let all = GenerationWrite.stage([], original: .ja, in: f.set, replacingKinds: [.speech, .sound, .screen])
        #expect(all.removing == [f.a.id, f.b.id, f.c.id])
        let two = GenerationWrite.stage([], original: .ja, in: f.set, replacingKinds: [.sound, .screen])
        #expect(two.removing == [f.a.id, f.c.id])
        let none = GenerationWrite.stage([clip(8000, 9000)], original: .ja, in: f.set, replacingKinds: [])
        #expect(none.removing.isEmpty && none.adding.count == 1)
    }

    @Test func generationAddsOriginalLanguageAndKeepsOtherCells() {
        let f = make()
        var s = f.set
        try! s.removeLanguage(.en, original: .ja)
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [s]))
        let generated = [clip(8000, 9000, .speech, "Hello")]
        let write = GenerationWrite.stage(generated, original: .en, in: s, replacingKinds: [])
        #expect(write.removing.isEmpty)
        ed.apply(write, to: s.id, actionName: "자동 생성")
        let after = ed.set(s.id)!
        #expect(after.languages == [.ja, .ko, .en])
        #expect(after.cues.count == 4)
        #expect(after.cues.last?.texts == [.en: "Hello"])
        #expect(Array(after.cues.prefix(3)) == s.cues)
    }

    @Test func emptyWriteChangesNothing() {
        let f = make()
        let ed = editor(f)
        #expect(ed.apply(CueWrite(language: .ja), to: f.set.id, actionName: "자동 생성"))
        #expect(!ed.undoManager.canUndo)
        #expect(!ed.apply(CueWrite(language: .ja), to: UUID(), actionName: "자동 생성"))
    }

    /// 지우는 종류의 조각과는 견주지 않으니 찾은 결과를 모두 넣는다. 남는 조각과는 `dedupe`대로 견준다.
    @Test func replaceStageDedupesOnlyAgainstKeptCues() {
        let f = make()
        let sameSound = SubtitleClip(start: 5000, end: 6000, kind: .sound, text: "銃声")
        let sameScreen = SubtitleClip(start: 0, end: 1000, kind: .screen, text: "第三埠頭")
        let replace = GenerationWrite.stage([sameSound], original: .ja, in: f.set, replacingKinds: [.sound],
                                            dedupe: .sounds)
        #expect(replace.adding.map(\.id) == [sameSound.id])
        #expect(replace.removing == [f.c.id])
        let screen = GenerationWrite.stage([sameScreen], original: .ja, in: f.set, replacingKinds: [.screen],
                                           dedupe: .screenText)
        #expect(screen.adding.map(\.id) == [sameScreen.id])
        // 지우지 않을 때는 이미 있는 같은 조각을 다시 넣지 않는다(멈춘 생성을 이어 할 때).
        #expect(GenerationWrite.stage([sameSound], original: .ja, in: f.set, replacingKinds: [.speech],
                                      dedupe: .sounds).adding.isEmpty)
        #expect(GenerationWrite.stage([sameScreen], original: .ja, in: f.set, replacingKinds: [],
                                      dedupe: .screenText).adding.isEmpty)
        let ed = editor(f)
        ed.apply(replace, to: f.set.id, actionName: "자동 생성")
        #expect(Set(ed.set(f.set.id)!.cues.map(\.id)) == [f.a.id, f.b.id, sameSound.id])
    }

    @Test func replaceDecisionFollowsProgress() {
        var g = GenerationProgress(options: GenerationOptions(transcribe: false))
        #expect(g.replacesExistingCues)
        g.soundsClassified = true
        #expect(!g.replacesExistingCues)
    }

    /// 시트의 경고: 고른 트랙 중 조각이 있는 것만 화면, 음성, 소리 순으로 센다.
    @Test func regenerationWarningCountsChosenTracksWithCues() {
        var f = make().set
        f.cues.append(Cue(start: 7000, end: 8000, kind: .speech, texts: [.ja: "よし"]))
        #expect(GenerationOptions().replacingWarning(in: f) == "고른 트랙(화면 1개, 음성 2개, 소리 1개)의 기존 자막이 지워져요")
        #expect(GenerationOptions(screenText: false).replacingWarning(in: f) == "고른 트랙(음성 2개, 소리 1개)의 기존 자막이 지워져요")
        f.cues.removeAll { $0.kind == .sound }
        #expect(GenerationOptions(transcribe: false, screenText: false).replacingWarning(in: f) == nil)
        #expect(GenerationOptions(transcribe: false).replacingWarning(in: f) == "고른 트랙(화면 1개)의 기존 자막이 지워져요")
    }

    /// 지울 조각에 걸린 티켓이 있으면 경고에 함께 센다(다른 트랙의 티켓은 세지 않는다).
    @Test func regenerationWarningCountsTicketsOnRemovedCues() {
        let f = make()
        let book = TicketBook(tickets: [suspect(f.set.id, f.b.id, .ko), suspect(f.set.id, f.a.id, .en),
                                        suspect(UUID(), f.b.id, .ko)])
        #expect(GenerationOptions(sounds: false, screenText: false).replacingWarning(in: f.set, tickets: book)
            == "고른 트랙(음성 1개)의 기존 자막이 지워지고, 걸린 티켓 1개도 함께 지워져요")
        #expect(GenerationOptions(transcribe: false, screenText: false).replacingWarning(in: f.set, tickets: book)
            == "고른 트랙(소리 1개)의 기존 자막이 지워져요")
    }

    /// 다시 번역 경고의 티켓 수: 자막셋 전체는 그 언어 티켓 모두, 고른 조각은 다시 쓰는 칸에 걸린 그 언어 티켓만.
    @Test func retranslationCountsTicketsCleared() {
        var f = make()
        var s = f.set
        s.cues[0].texts[.ko] = "제3부두"
        f = Fixture(set: s, a: s.cues[0], b: f.b, c: f.c)
        let book = TicketBook(tickets: [suspect(s.id, f.a.id, .ko), suspect(s.id, f.b.id, .ko),
                                        suspect(s.id, f.b.id, .en), suspect(s.id, f.c.id, .ko, before: "")])
        #expect(TranslationWrite.ticketsCleared(in: s, tickets: book, source: .ja, target: .ko, scope: nil) == 3)
        #expect(TranslationWrite.ticketsCleared(in: s, tickets: book, source: .ja, target: .ko, scope: [f.b.id]) == 1)
        // c는 번역 칸이 비어 다시 쓰지 않는다.
        #expect(TranslationWrite.ticketsCleared(in: s, tickets: book, source: .ja, target: .ko, scope: [f.c.id]) == 0)
    }
}
