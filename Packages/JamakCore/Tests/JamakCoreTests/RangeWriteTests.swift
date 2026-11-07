import Testing
import Foundation
@testable import JamakCore

/// 구간 작업(구간·조각 다시 받아쓰기, 화면 글자 찾기)의 결과로 조각을 바꿀 때 다른 언어 문장을 잃지 않는다.
@MainActor
@Suite struct RangeWriteTests {
    /// 자막셋(ko 기본 + ja + en).
    func set(_ cues: [Cue]) -> CueSet {
        var s = CueSet.initial(language: .ko)
        try! s.addLanguage(.ja)
        try! s.addLanguage(.en)
        s.cues = cues
        return s
    }

    func clip(_ start: Int, _ end: Int, _ kind: SubtitleKind = .speech, _ text: String) -> SubtitleClip {
        SubtitleClip(start: start, end: end, kind: kind, text: text)
    }

    func apply(_ write: CueWrite, to s: CueSet) -> SubtitleDataEditor {
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [s]))
        #expect(ed.apply(write, to: s.id, actionName: "구간 다시 받아쓰기"))
        return ed
    }

    @Test func oneResultForOneTargetReusesIdAndKeepsOtherLanguages() {
        let a = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "가", .ja: "あ", .en: "a"])
        let s = set([a])
        let results = [clip(900, 2100, .speech, "가나"), clip(2100, 2500, .sound, "(총성)")]
        let write = RangeWrite.replacing([a.id], with: results, language: .ko, in: s)
        #expect(write.adding.first { $0.kind == .speech }?.id == a.id)
        #expect(write.tickets.isEmpty && write.carried.isEmpty)

        let ed = apply(write, to: s)
        let out = ed.set(s.id)!
        #expect(out.cues.count == 2)
        let cue = out.cues.first { $0.id == a.id }!
        #expect(cue.start == 900 && cue.end == 2100)
        #expect(cue.text(.ko) == "가나" && cue.text(.ja) == "あ" && cue.text(.en) == "a")
        #expect(ed.tickets.tickets.isEmpty)
    }

    @Test func reusedCueDropsStaleTicketsOfReplacedCellOnly() {
        let a = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "가", .ja: "あ"])
        let s = set([a])
        func suspect(_ language: Language, _ reason: String) -> Ticket {
            Ticket(setID: s.id, origin: .translation, language: language, level: .suspect, reason: reason,
                   changes: [TicketChange(cueID: a.id, before: a.text(language), after: "")])
        }
        let tickets = TicketBook(tickets: [suspect(.ko, "옛 문장 오타"), suspect(.ja, "번역 확인")])
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [s]), tickets: tickets)
        let write = RangeWrite.replacing([a.id], with: [clip(1000, 2000, .speech, "가가")], language: .ko, in: s)
        ed.apply(write, to: s.id, actionName: "이 조각 다시 받아쓰기")
        #expect(ed.tickets.tickets.map(\.reason) == ["번역 확인"])
    }

    @Test func otherwiseCarriesToLargestOverlapSameKindWithCheckTickets() {
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "가", .ja: "あ"])
        let b = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "나", .ja: "い", .en: "i"])
        let s = set([a, b])
        // r1은 a와 1000, b와 200 겹치고 r2는 b와 800 겹친다. 소리 조각은 받지 않는다.
        let r1 = clip(0, 1200, .speech, "가가")
        let r2 = clip(1200, 2000, .speech, "나나")
        let noise = clip(1000, 2000, .sound, "(소리)")
        let write = RangeWrite.replacing([a.id, b.id], with: [r1, noise, r2], language: .ko, in: s)
        #expect(Set(write.adding.map(\.id)).isDisjoint(with: [a.id, b.id]))
        #expect(write.removing == [a.id, b.id])
        #expect(write.carried[r1.id] == [.ja: "あ"])
        #expect(write.carried[r2.id] == [.ja: "い", .en: "i"])
        #expect(write.carried[noise.id] == nil)

        let ed = apply(write, to: s)
        let out = ed.set(s.id)!
        #expect(out.cues.first { $0.id == r1.id }?.texts == [.ko: "가가", .ja: "あ"])
        #expect(out.cues.first { $0.id == r2.id }?.texts == [.ko: "나나", .ja: "い", .en: "i"])
        let tickets = ed.tickets.tickets
        #expect(tickets.count == 3)
        #expect(tickets.allSatisfy {
            $0.level == .suspect && $0.origin == .translation && $0.setID == s.id
                && $0.reason == Ticket.timingChangedReason && $0.changes.count == 1 && $0.changes[0].after == ""
        })
        #expect(Set(tickets.map { "\($0.cueIDs == [r1.id] ? "r1" : "r2")/\($0.language.rawValue)" })
                == ["r1/ja", "r2/ja", "r2/en"])
        #expect(tickets.first { $0.cueIDs == [r2.id] && $0.language == .ja }?.changes[0].before == "い")
    }

    @Test func severalTargetsIntoOneResultJoinInTimeOrder() {
        let b = Cue(start: 1000, end: 2000, kind: .screen, texts: [.ko: "나", .ja: "い"])
        let a = Cue(start: 0, end: 1000, kind: .screen, texts: [.ko: "가", .ja: "あ"])
        let s = set([a, b])
        let r = clip(0, 2000, .screen, "가나")
        let write = RangeWrite.replacing([a.id, b.id], with: [r], language: .ko, in: s)
        #expect(write.carried[r.id] == [.ja: "あ\nい"])
        #expect(write.tickets.count == 1)
    }

    @Test func noOverlapCarriesToNearestSameKind() {
        let a = Cue(start: 5000, end: 6000, kind: .speech, texts: [.ko: "가", .en: "a"])
        let b = Cue(start: 6000, end: 7000, kind: .speech, texts: [.ko: "나"])
        let s = set([a, b])
        let near = clip(6100, 7000, .speech, "나")
        let far = clip(0, 1000, .speech, "먼")
        let write = RangeWrite.replacing([a.id, b.id], with: [far, near], language: .ko, in: s)
        #expect(write.carried == [near.id: [.en: "a"]])
    }

    @Test func originalOnlyTargetsCarryNothing() {
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "가"])
        let b = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "나"])
        let s = set([a, b])
        let write = RangeWrite.replacing([a.id, b.id], with: [clip(0, 2000, .speech, "가나")], language: .ko, in: s)
        #expect(write.carried.isEmpty && write.tickets.isEmpty)
        #expect(!RangeWrite.losesOtherLanguages([a.id, b.id], in: s, original: .ko))
    }

    @Test func noSameKindResultReportsLoss() {
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "가", .ja: "あ"])
        let s = set([a])
        #expect(RangeWrite.losesOtherLanguages([a.id], in: s, original: .ko))
        // 대사가 없는 결과로 지우기로 했으면(사용자가 확인함) 옮길 곳이 없다.
        let write = RangeWrite.replacing([a.id], with: [clip(0, 500, .sound, "(소리)")], language: .ko, in: s)
        #expect(write.carried.isEmpty && write.removing == [a.id])
    }

    @Test func undoRestoresRemovedCuesAndDropsCarriedTickets() {
        let a = Cue(start: 0, end: 1000, kind: .speech, texts: [.ko: "가", .ja: "あ"])
        let b = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "나", .ja: "い"])
        let s = set([a, b])
        let ed = apply(RangeWrite.replacing([a.id, b.id], with: [clip(0, 2000, .speech, "가나")],
                                            language: .ko, in: s), to: s)
        #expect(ed.tickets.tickets.count == 1)
        ed.undoManager.undo()
        #expect(ed.set(s.id)!.cues == s.cues)
        #expect(ed.tickets.tickets.isEmpty)
    }
}
