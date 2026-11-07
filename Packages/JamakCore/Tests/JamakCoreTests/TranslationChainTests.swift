import Testing
import Foundation
@testable import JamakCore

/// 번역 결과 쓰기: 칸에 바로 쓰고 티켓은 만들지 않는다. 전체 다시 번역은 그 언어 티켓을 지운다.
@MainActor
@Suite struct TranslationChainTests {
    /// ja·ko 자막셋: a(ko 빈 칸), b(ko 있음), c(ko 있음).
    struct Fixture {
        let set: CueSet
        let a: Cue, b: Cue, c: Cue
    }

    func make() -> Fixture {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "やあ"])
        let b = Cue(start: 2000, end: 3000, kind: .speech, texts: [.ja: "どこだ", .ko: "손으로 쓴 번역"])
        let c = Cue(start: 4000, end: 5000, kind: .speech, texts: [.ja: "誰だ", .ko: "누구야"])
        s.cues = [a, b, c]
        return Fixture(set: s, a: a, b: b, c: c)
    }

    func ticket(_ set: UUID, _ cue: UUID, _ language: Language, origin: Ticket.Origin = .translation,
                before: String) -> Ticket {
        Ticket(setID: set, origin: origin, language: language, level: .suspect, reason: "이상해요",
               changes: [TicketChange(cueID: cue, before: before, after: "")])
    }

    @Test func fillEmptyKeepsExistingAndTickets() {
        let f = make()
        let kept = ticket(f.set.id, f.b.id, .ko, before: "손으로 쓴 번역")
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: [kept]))

        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: nil, fillEmptyOnly: true)
        #expect(sources.map(\.id) == [f.a.id])
        // 그사이 채워진 칸(b)의 결과가 와도 쓰지 않는다.
        let write = TranslationWrite.write([f.a.id: "안녕", f.b.id: "어디냐"], sources: sources + [
            SubtitleClip(id: f.b.id, start: 2000, end: 3000, kind: .speech, text: "どこだ"),
        ], in: f.set, target: .ko, fillEmptyOnly: true)
        #expect(write.tickets.isEmpty && !write.clearsLanguageTickets)
        ed.apply(write, to: f.set.id, actionName: "번역")
        let s = ed.set(f.set.id)!
        #expect(s.cues.map { $0.text(.ko) } == ["안녕", "손으로 쓴 번역", "누구야"])
        #expect(ed.tickets.tickets == [kept])
    }

    @Test func fullRetranslateClearsLanguageTickets() {
        let f = make()
        let onB = ticket(f.set.id, f.b.id, .ko, before: "손으로 쓴 번역")
        let onC = ticket(f.set.id, f.c.id, .ko, before: "누구야")
        let source = ticket(f.set.id, f.a.id, .ja, origin: .source, before: "やあ")
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: [onB, onC, source]))

        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: nil, fillEmptyOnly: false)
        #expect(sources.map(\.id) == [f.a.id, f.b.id, f.c.id])
        // c는 응답을 받지 못했다: 칸은 그대로 두고 티켓을 만들지 않는다.
        let write = TranslationWrite.write([f.a.id: "안녕", f.b.id: "어디냐"], sources: sources, in: f.set,
                                           target: .ko, fillEmptyOnly: false, clearsTickets: true)
        #expect(write.tickets.isEmpty && write.clearsLanguageTickets)
        ed.apply(write, to: f.set.id, actionName: "번역")
        let s = ed.set(f.set.id)!
        #expect(s.cues.map { $0.text(.ko) } == ["안녕", "어디냐", "누구야"])
        // ko 티켓은 모두 지우고(바뀌지 않은 c도), 원문 티켓은 그대로다.
        #expect(ed.tickets.tickets == [source])
        // 실행 취소하면 티켓도 돌아온다.
        ed.undoManager.undo()
        #expect(Set(ed.tickets.tickets.map(\.id)) == Set([onB.id, onC.id, source.id]))
    }

    @Test func scopedRetranslateReplacesChosenCellsWithoutTickets() {
        let f = make()
        let onC = ticket(f.set.id, f.c.id, .ko, before: "누구야")
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: [onC]))
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: [f.b.id], fillEmptyOnly: false)
        #expect(sources.map(\.id) == [f.b.id])
        let write = TranslationWrite.write([f.b.id: "어디냐"], sources: sources, in: f.set, target: .ko,
                                           fillEmptyOnly: false)
        ed.apply(write, to: f.set.id, actionName: "번역")
        #expect(ed.set(f.set.id)!.cues.map { $0.text(.ko) } == ["", "어디냐", "누구야"])
        // 범위 밖 칸의 티켓은 그대로다.
        #expect(ed.tickets.tickets == [onC])
    }

    @Test func scopedRetranslateClosesSourceChangedTicketEvenIfTextSame() {
        let f = make()
        // b: 원문 변경 티켓, c: 제안이 있는 다른 번역 티켓. 둘 다 다시 번역했고 결과가 지금 문장과 같다.
        var changed = ticket(f.set.id, f.b.id, .ko, before: "손으로 쓴 번역")
        changed.reason = Ticket.sourceChangedReason
        var other = ticket(f.set.id, f.c.id, .ko, before: "누구야")
        other.level = .suspect
        other.changes[0].after = "누구냐"
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: [changed, other]))
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: [f.b.id, f.c.id],
                                               fillEmptyOnly: false)
        let write = TranslationWrite.write([f.b.id: "손으로 쓴 번역", f.c.id: "누구야"], sources: sources, in: f.set,
                                           target: .ko, fillEmptyOnly: false)
        #expect(write.texts.isEmpty && write.retranslated == [f.b.id, f.c.id])
        ed.apply(write, to: f.set.id, actionName: "번역")
        // 원문 변경 티켓만 닫는다. 제안이 있는 판단은 문장이 그대로니 남는다.
        #expect(ed.tickets.tickets == [other])
        ed.undoManager.undo()
        #expect(ed.tickets.tickets == [changed, other])
    }

    @Test func scopedRetranslateClosesProposalLessTicketEvenIfTextSame() {
        let f = make()
        // c: 제안 없는 의심 티켓에 [다시 번역]으로 답했다. 결과가 지금 문장과 같아도 닫힌다.
        let bare = ticket(f.set.id, f.c.id, .ko, before: "누구야")
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [f.set]), tickets: TicketBook(tickets: [bare]))
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: [f.c.id],
                                               fillEmptyOnly: false)
        let write = TranslationWrite.write([f.c.id: "누구야"], sources: sources, in: f.set,
                                           target: .ko, fillEmptyOnly: false)
        ed.apply(write, to: f.set.id, actionName: "번역")
        #expect(ed.tickets.tickets.isEmpty)
        ed.undoManager.undo()
        #expect(ed.tickets.tickets == [bare])
    }

    @Test func fillEmptyOnlyDoesNotMarkRetranslated() {
        let f = make()
        let sources = TranslationWrite.sources(in: f.set, source: .ja, target: .ko, scope: nil, fillEmptyOnly: true)
        let write = TranslationWrite.write([f.a.id: "안녕"], sources: sources, in: f.set, target: .ko,
                                           fillEmptyOnly: true)
        #expect(write.retranslated.isEmpty)
    }
}
