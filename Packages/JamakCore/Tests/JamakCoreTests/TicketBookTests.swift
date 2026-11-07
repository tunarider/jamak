import Testing
import Foundation
@testable import JamakCore

@MainActor
@Suite struct TicketBookTests {
    struct Fixture {
        let editor: SubtitleDataEditor
        let setID: UUID
        let a: Cue
        let b: Cue
        let c: Cue
    }

    /// 자막셋 하나(작품 원어 ja + ko), 조각 셋. c는 ko 칸이 비었다.
    func make() -> Fixture {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "やあ", .ko: "안녕"])
        let b = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ja: "さよなら", .ko: "잘 가"])
        let c = Cue(start: 2000, end: 3000, kind: .speech, texts: [.ja: "うん"])
        s.cues = [a, b, c]
        return Fixture(editor: SubtitleDataEditor(data: SubtitleData(sets: [s])), setID: s.id, a: a, b: b, c: c)
    }

    func ticket(_ f: Fixture, _ level: Ticket.Level, origin: Ticket.Origin = .translation, language: Language = .ko,
                _ changes: [(Cue, String)]) -> Ticket {
        Ticket(setID: f.setID, origin: origin, language: language, level: level, reason: "이유",
               changes: changes.map { TicketChange(cueID: $0.0.id, before: $0.0.text(language), after: $0.1) })
    }

    func text(_ f: Fixture, _ cue: Cue, _ language: Language = .ko) -> String {
        f.editor.set(f.setID)!.cues.first { $0.id == cue.id }!.text(language)
    }

    @Test func openFixWritesAfterAndUndoRestores() {
        let f = make()
        let t = ticket(f, .fix, [(f.a, "안녕하세요"), (f.b, "잘 가요")])
        let opened = f.editor.open([t])
        #expect(opened == [t])
        #expect(text(f, f.a) == "안녕하세요" && text(f, f.b) == "잘 가요")
        #expect(f.editor.tickets.tickets == [t])
        f.editor.undoManager.undo()
        #expect(text(f, f.a) == "안녕" && text(f, f.b) == "잘 가")
        #expect(f.editor.tickets.tickets.isEmpty)
        #expect(!f.editor.undoManager.canUndo)
        f.editor.undoManager.redo()
        #expect(text(f, f.a) == "안녕하세요")
        #expect(f.editor.tickets.tickets == [t])
    }

    @Test func openSuspectKeepsBefore() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "안녕하세요")])
        #expect(f.editor.open([t]) == [t])
        #expect(text(f, f.a) == "안녕")
        #expect(f.editor.tickets.ticket(set: f.setID, cue: f.a.id, language: .ko) == t)
        #expect(f.editor.tickets.cueIDs(set: f.setID, level: .suspect) == [f.a.id])
        #expect(f.editor.tickets.cueIDs(set: f.setID, level: .fix).isEmpty)
    }

    @Test func openDropsInvalidChanges() {
        let f = make()
        let unchanged = ticket(f, .fix, [(f.a, "안녕")])
        let missingCue = Ticket(setID: f.setID, origin: .translation, language: .ko, level: .fix, reason: "",
                                changes: [TicketChange(cueID: UUID(), before: "", after: "x")])
        let missingLanguage = ticket(f, .fix, language: .en, [(f.a, "hi")])
        let mixed = ticket(f, .fix, [(f.a, "안녕"), (f.b, "잘 가요")])
        let opened = f.editor.open([unchanged, missingCue, missingLanguage, mixed])
        #expect(opened.map(\.id) == [mixed.id])
        #expect(opened[0].changes.map(\.cueID) == [f.b.id])
        #expect(f.editor.open([unchanged]).isEmpty)
    }

    @Test func applySuspectWritesAfter() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "안녕하세요")])
        f.editor.open([t])
        f.editor.apply(ticket: t.id)
        #expect(text(f, f.a) == "안녕하세요")
        #expect(f.editor.tickets.tickets.isEmpty)
    }

    @Test func applySuspectWithoutProposalKeepsText() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "")])
        f.editor.open([t])
        f.editor.apply(ticket: t.id)
        #expect(text(f, f.a) == "안녕")
        #expect(f.editor.tickets.tickets.isEmpty)
    }

    @Test func rejectFixRestoresBefore() {
        let f = make()
        let t = ticket(f, .fix, [(f.a, "안녕하세요")])
        f.editor.open([t])
        f.editor.reject(ticket: t.id)
        #expect(text(f, f.a) == "안녕")
        #expect(f.editor.tickets.tickets.isEmpty)
    }

    @Test func applyFixKeepsAfter() {
        let f = make()
        let t = ticket(f, .fix, [(f.a, "안녕하세요")])
        f.editor.open([t])
        f.editor.apply(ticket: t.id)
        #expect(text(f, f.a) == "안녕하세요")
        #expect(f.editor.tickets.tickets.isEmpty)
    }

    @Test func rejectSuspectKeepsBefore() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "안녕하세요")])
        f.editor.open([t])
        f.editor.reject(ticket: t.id)
        #expect(text(f, f.a) == "안녕")
        #expect(f.editor.tickets.tickets.isEmpty)
    }

    @Test func oneOpenTicketPerCell() {
        let f = make()
        let first = ticket(f, .suspect, [(f.a, "안녕하세요")])
        f.editor.open([first])
        let second = ticket(f, .fix, [(f.a, "하이"), (f.b, "잘 가요")])
        let opened = f.editor.open([second])
        #expect(opened.count == 1 && opened[0].changes.map(\.cueID) == [f.b.id])
        #expect(text(f, f.a) == "안녕" && text(f, f.b) == "잘 가요")
        #expect(f.editor.tickets.ticket(set: f.setID, cue: f.a.id, language: .ko)?.id == first.id)
        // 한 번에 연 티켓끼리 겹치면 먼저 나온 것이 남는다.
        let g = make()
        let x = ticket(g, .suspect, [(g.a, "가")])
        let y = ticket(g, .suspect, [(g.a, "나")])
        #expect(g.editor.open([x, y]).map(\.id) == [x.id])
        // 같은 조각의 다른 언어 칸은 따로다.
        let ja = ticket(g, .suspect, origin: .source, language: .ja, [(g.a, "やぁ")])
        #expect(g.editor.open([ja]).map(\.id) == [ja.id])
    }

    @Test func manualEditClosesTicket() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "안녕하세요"), (f.b, "잘 가요")])
        f.editor.open([t])
        f.editor.setText("안뇽", cue: f.a.id, language: .ko, in: f.setID, actionName: "문장 수정")
        #expect(f.editor.tickets.tickets.isEmpty)
        f.editor.undoManager.undo()
        #expect(f.editor.tickets.tickets == [t])
        // 다른 언어 칸을 고치면 그대로다.
        f.editor.setText("やぁ", cue: f.a.id, language: .ja, in: f.setID, actionName: "문장 수정")
        #expect(f.editor.tickets.tickets == [t])
    }

    @Test func applyingSourceTicketOpensRetranslateTickets() {
        let f = make()
        let src = ticket(f, .suspect, origin: .source, language: .ja, [(f.a, "やあ!"), (f.c, "ううん")])
        let old = ticket(f, .suspect, [(f.a, "안녕?")])
        f.editor.open([src, old])
        f.editor.undoManager.removeAllActions()
        f.editor.apply(ticket: src.id)
        #expect(text(f, f.a, .ja) == "やあ!")
        let retranslate = f.editor.tickets.tickets
        // c는 ko 칸이 비어 있어 티켓이 없다. a의 예전 번역 티켓은 바뀐다.
        #expect(retranslate.count == 1)
        let r = retranslate[0]
        #expect(r.origin == .translation && r.language == .ko && r.level == .suspect)
        #expect(r.reason == Ticket.sourceChangedReason)
        #expect(r.changes == [TicketChange(cueID: f.a.id, before: "안녕", after: "")])
        // 반영과 생성은 한 단계다.
        f.editor.undoManager.undo()
        #expect(!f.editor.undoManager.canUndo)
        #expect(Set(f.editor.tickets.tickets.map(\.id)) == [src.id, old.id])
        #expect(text(f, f.a, .ja) == "やあ")

        // 고침을 미반영하면 원래대로라 만들지 않는다.
        let g = make()
        let fix = ticket(g, .fix, origin: .source, language: .ja, [(g.a, "やあ!")])
        g.editor.open([fix])
        g.editor.reject(ticket: fix.id)
        #expect(g.editor.tickets.tickets.isEmpty)
        #expect(text(g, g.a, .ja) == "やあ")
        // 고침을 반영하면 만든다.
        g.editor.open([fix])
        g.editor.apply(ticket: fix.id)
        #expect(g.editor.tickets.tickets.map(\.reason) == [Ticket.sourceChangedReason])
    }

    @Test func deletedCueDropsTickets() {
        let f = make()
        let t = ticket(f, .suspect, [(f.a, "안녕하세요"), (f.b, "잘 가요")])
        let other = ticket(f, .suspect, origin: .source, language: .ja, [(f.c, "ううん")])
        f.editor.open([t, other])
        f.editor.deleteCue(f.a.id, in: f.setID)
        #expect(f.editor.tickets.tickets.map(\.changes.count) == [1, 1])
        #expect(f.editor.tickets.ticket(set: f.setID, cue: f.b.id, language: .ko)?.id == t.id)
        f.editor.deleteCue(f.b.id, in: f.setID)
        #expect(f.editor.tickets.tickets.map(\.id) == [other.id])
        f.editor.replaceCues(in: f.setID, removing: [f.c.id], adding: [], language: .ja, actionName: "구간 교체")
        #expect(f.editor.tickets.tickets.isEmpty)
        f.editor.undoManager.undo()
        f.editor.undoManager.undo()
        f.editor.undoManager.undo()
        #expect(f.editor.tickets.tickets.count == 2)
    }

    @Test func exportUsesCurrentCellText() {
        let f = make()
        f.editor.open([ticket(f, .fix, [(f.a, "안녕하세요")]), ticket(f, .suspect, [(f.b, "잘 가요")])])
        let srt = CueSRT.export(f.editor.set(f.setID)!, language: .ko, original: .ja, fallback: false)
        #expect(srt.contains("안녕하세요"))
        #expect(srt.contains("잘 가\n") && !srt.contains("잘 가요"))
    }

    @Test func bookQueriesAndNavigation() {
        let f = make()
        let ta = ticket(f, .fix, [(f.a, "안녕하세요")])
        let tc = ticket(f, .suspect, origin: .source, language: .ja, [(f.c, "ううん")])
        f.editor.open([tc, ta])
        let book = f.editor.tickets
        let set = f.editor.set(f.setID)!
        // 첫 조각 시간 순서.
        #expect(book.tickets(set: f.setID).map(\.id) == [ta.id, tc.id])
        #expect(book.cueIDs(set: f.setID, level: nil) == [f.a.id, f.c.id])
        #expect(book.next(after: nil, in: set) == f.a.id)
        #expect(book.next(after: f.a.id, in: set) == f.c.id)
        #expect(book.next(after: f.c.id, in: set) == f.a.id)
        #expect(book.previous(before: f.a.id, in: set) == f.c.id)
        #expect(book.previous(before: nil, in: set) == f.c.id)
        #expect(TicketBook().next(after: nil, in: set) == nil)

        var copy = book
        copy.removeAll(set: f.setID, language: .ja)
        #expect(copy.tickets.map(\.id) == [ta.id])
        copy.removeAll(set: f.setID, cues: [f.a.id])
        #expect(copy.tickets.isEmpty)
        copy = book
        copy.removeAll(set: f.setID)
        #expect(copy.tickets.isEmpty)
    }

    @Test func ticketsSurviveCoding() throws {
        let f = make()
        f.editor.open([ticket(f, .fix, [(f.a, "안녕하세요")])])
        let data = try JSONEncoder().encode(f.editor.tickets)
        #expect(try JSONDecoder().decode(TicketBook.self, from: data) == f.editor.tickets)
    }

    @Test func filterMatchesLanguageAndLevel() {
        let f = make()
        let fixKo = ticket(f, .fix, [(f.a, "안녕하세요")])
        let suspectJa = ticket(f, .suspect, origin: .source, language: .ja, [(f.b, "さようなら")])
        let list = [fixKo, suspectJa]
        #expect(list.filter(TicketFilter().matches) == list)
        #expect(list.filter(TicketFilter(language: .ja).matches) == [suspectJa])
        #expect(list.filter(TicketFilter(level: .fix).matches) == [fixKo])
        #expect(list.filter(TicketFilter(language: .ko, level: .suspect).matches).isEmpty)
        // 자막셋에 없는 언어는 전체로 푼다(단계는 그대로).
        #expect(TicketFilter(language: .en, level: .fix).resolved(languages: [.ja, .ko]) == TicketFilter(level: .fix))
        #expect(TicketFilter(language: .ko).resolved(languages: [.ja, .ko]) == TicketFilter(language: .ko))
    }

    @Test func neighborWrapsAndFollowsCuePosition() {
        let f = make()
        let ta = ticket(f, .fix, [(f.a, "안녕하세요")])
        let tb = ticket(f, .suspect, [(f.b, "잘 가요")])
        let tc = ticket(f, .suspect, origin: .source, language: .ja, [(f.c, "うんうん")])
        let list = [ta, tb, tc]
        let order = [f.a.id, f.b.id, f.c.id]
        // 고른 티켓의 옆, 끝에서 돈다.
        #expect(TicketBook.neighbor(of: tb.id, near: nil, in: list, order: order, forward: true) == tc)
        #expect(TicketBook.neighbor(of: tc.id, near: nil, in: list, order: order, forward: true) == ta)
        #expect(TicketBook.neighbor(of: ta.id, near: nil, in: list, order: order, forward: false) == tc)
        // 고른 티켓이 목록에 없으면 고른 조각의 자리에서.
        #expect(TicketBook.neighbor(of: UUID(), near: f.a.id, in: list, order: order, forward: true) == tb)
        #expect(TicketBook.neighbor(of: nil, near: f.b.id, in: list, order: order, forward: false) == ta)
        #expect(TicketBook.neighbor(of: nil, near: f.c.id, in: list, order: order, forward: true) == ta)
        // 아무것도 없으면 처음·끝.
        #expect(TicketBook.neighbor(of: nil, near: nil, in: list, order: order, forward: true) == ta)
        #expect(TicketBook.neighbor(of: nil, near: nil, in: list, order: order, forward: false) == tc)
        #expect(TicketBook.neighbor(of: nil, near: nil, in: [], order: order, forward: true) == nil)
    }

    @Test func successorPrefersNextRemaining() {
        let f = make()
        let ta = ticket(f, .fix, [(f.a, "안녕하세요")])
        let tb = ticket(f, .suspect, [(f.b, "잘 가요")])
        let tc = ticket(f, .suspect, origin: .source, language: .ja, [(f.c, "うんうん")])
        #expect(TicketBook.successor(of: tb.id, before: [ta, tb, tc], after: [ta, tc]) == tc)
        #expect(TicketBook.successor(of: tc.id, before: [ta, tb, tc], after: [ta, tb]) == tb)
        #expect(TicketBook.successor(of: ta.id, before: [ta], after: []) == nil)
        // 처리로 새로 생긴 티켓만 남으면 그것.
        #expect(TicketBook.successor(of: ta.id, before: [ta], after: [tc]) == tc)
        // 보이지 않던 티켓은 옮기지 않는다.
        #expect(TicketBook.successor(of: UUID(), before: [ta, tb], after: [ta, tb]) == nil)
    }

    @Test func cueIDsByLanguage() {
        let f = make()
        f.editor.open([ticket(f, .fix, [(f.a, "안녕하세요")]),
                       ticket(f, .suspect, origin: .source, language: .ja, [(f.b, "さようなら")])])
        let book = f.editor.tickets
        #expect(book.cueIDs(set: f.setID, level: nil, language: .ko) == [f.a.id])
        #expect(book.cueIDs(set: f.setID, level: .suspect, language: .ja) == [f.b.id])
        #expect(book.cueIDs(set: f.setID, level: .fix, language: .ja).isEmpty)
    }
}
