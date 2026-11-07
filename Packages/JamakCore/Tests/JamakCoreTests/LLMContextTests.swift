import Testing
import Foundation
@testable import JamakCore

@Suite struct LLMContextTests {
    func makeSet(_ n: Int) -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = (0..<n).map { i in
            Cue(start: i * 1000, end: i * 1000 + 900, kind: .speech, texts: [.ja: "원\(i)", .ko: "번\(i)"])
        }
        return s
    }

    @Test func linesIncludeNeighborsAsContext() {
        let s = makeSet(20)
        let target = s.cuesInTimelineOrder[10].id
        let lines = LLMContext.lines(set: s, original: .ja, translation: .ko, targets: [target])
        // 10번째 인덱스 조각: 앞 10줄(처음에서 잘림 없이 0~9), 뒤 5줄(11~15)
        #expect(lines.map(\.id) == ["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16"])
        let targets = lines.filter { $0.context != true }
        #expect(targets.map(\.id) == ["11"])
        #expect(lines.filter { $0.context == true }.count == 15)
        #expect(lines[10].source == "원10")
        #expect(lines[10].translation == "번10")
        #expect(lines[10].kind == "speech")
    }

    @Test func sourceOnlyHasNoTranslation() {
        let s = makeSet(3)
        let lines = LLMContext.lines(set: s, original: .ja, translation: nil, targets: Set(s.cues.map(\.id)))
        #expect(lines.allSatisfy { $0.translation == nil && $0.context == nil })
    }

    @Test func timeFormat() {
        var s = CueSet.initial(language: .ja)
        let c = Cue(start: 221_340, end: 223_900, kind: .sound, texts: [.ja: "x"])
        s.cues = [c]
        let l = LLMContext.lines(set: s, original: .ja, translation: nil, targets: [c.id])
        #expect(l[0].time == "03:41.3–03:43.9")
        s.cues = [Cue(start: 3_661_000, end: 3_662_500, kind: .speech)]
        let h = LLMContext.lines(set: s, original: .ja, translation: nil, targets: [s.cues[0].id])
        #expect(h[0].time == "1:01:01.0–1:01:02.5")
    }

    @Test func cueIDForLine() {
        let s = makeSet(5)
        #expect(LLMContext.cueID(forLineID: "3", in: s) == s.cuesInTimelineOrder[2].id)
        #expect(LLMContext.cueID(forLineID: "0", in: s) == nil)
        #expect(LLMContext.cueID(forLineID: "6", in: s) == nil)
        #expect(LLMContext.cueID(forLineID: "x", in: s) == nil)
    }

    @Test func memoBlockOnlyOverlapping() {
        var s = makeSet(10)
        s.memos = [SceneMemo(start: 0, end: 2500, text: "첫 장면"),
                   SceneMemo(start: 7000, end: 9000, text: "먼 장면")]
        let lines = LLMContext.lines(set: s, original: .ja, translation: nil, targets: [s.cuesInTimelineOrder[1].id],
                                     before: 0, after: 1)
        let block = LLMContext.memoBlock(s.memos, covering: lines, in: s)
        #expect(block.contains("첫 장면"))
        #expect(!block.contains("먼 장면"))
        #expect(LLMContext.memoBlock([], covering: lines, in: s) == "(없음)")
        #expect(LLMContext.memoBlock(s.memos, covering: [], in: s) == "(없음)")
    }

    @Test func ticketBlockListsOpenTickets() {
        let s = makeSet(6)
        let ids = s.cuesInTimelineOrder.map(\.id)
        let t1 = Ticket(setID: s.id, origin: .translation, language: .ko, level: .suspect, reason: "어색해요",
                        changes: [TicketChange(cueID: ids[2], before: "전", after: "후")])
        let t2 = Ticket(setID: s.id, origin: .translation, language: .ko, level: .fix, reason: "멀어요",
                        changes: [TicketChange(cueID: ids[5], before: "a", after: "b")])
        let other = Ticket(setID: UUID(), origin: .source, language: .ja, level: .fix, reason: "남의 것",
                           changes: [TicketChange(cueID: ids[2], before: "a", after: "b")])
        let book = TicketBook(tickets: [t1, t2, other])
        let lines = LLMContext.lines(set: s, original: .ja, translation: .ko, targets: [ids[2]], before: 1, after: 1)
        let block = LLMContext.ticketBlock(book, set: s, lines: lines, original: .ja, translation: .ko)
        #expect(block.contains("[번역 ko] id 3: [의심] 어색해요 / 전 → 후"))
        #expect(!block.contains("멀어요"))
        #expect(!block.contains("남의 것"))
        #expect(LLMContext.ticketBlock(TicketBook(), set: s, lines: lines, original: .ja, translation: .ko) == "(없음)")
    }

    @Test func ticketBlockFiltersByReviewLanguagesAndLabels() throws {
        var s = makeSet(3)
        try s.addLanguage(.en)
        let ids = s.cuesInTimelineOrder.map(\.id)
        func t(_ language: Language, _ origin: Ticket.Origin, _ reason: String) -> Ticket {
            Ticket(setID: s.id, origin: origin, language: language, level: .suspect, reason: reason,
                   changes: [TicketChange(cueID: ids[1], before: "전", after: "")])
        }
        let book = TicketBook(tickets: [t(.ja, .source, "원문 이유"), t(.ko, .translation, "한국어 이유"),
                                        t(.en, .translation, "영어 이유")])
        let lines = LLMContext.lines(set: s, original: .ja, translation: nil, targets: [ids[1]])
        // 원문 검토: 원어 칸의 티켓만.
        let source = LLMContext.ticketBlock(book, set: s, lines: lines, original: .ja, translation: nil)
        #expect(source == "[원문] id 2: [의심] 원문 이유 / 전")
        // 번역 검토(ko): 원어 칸과 ko 칸의 티켓만, 칸 표시를 붙여서.
        let ko = LLMContext.ticketBlock(book, set: s, lines: lines, original: .ja, translation: .ko)
        #expect(ko == "[원문] id 2: [의심] 원문 이유 / 전\n[번역 ko] id 2: [의심] 한국어 이유 / 전")
        #expect(!ko.contains("영어 이유"))
    }

    func fakeLines(_ n: Int) -> [LLMLine] {
        (1...n).map { LLMLine(id: String($0), time: "t", kind: "speech", source: "s", translation: nil, context: nil) }
    }

    @Test func wholeRequestFallsBackToWindows() async throws {
        let calls = CallCounter()
        let results = try await WholeRequest.run(lines: fakeLines(700), forceWindows: false) { lines in
            let n = await calls.next()
            if n == 1 { throw LLMError.contextTooLong }
            return lines
        }
        #expect(results.count == 3)
        #expect(await calls.value == 4)
        let targets = results.flatMap { $0.filter { $0.context != true }.map(\.id) }
        #expect(targets == fakeLines(700).map(\.id))
        // 뒤 창의 앞쪽 겹침 줄은 context
        #expect(results[1].first?.context == true)
        #expect(results[0].first?.context == nil)
    }

    @Test func forceWindowsSkipsWholeAttempt() async throws {
        let calls = CallCounter()
        let results = try await WholeRequest.run(lines: fakeLines(700), forceWindows: true) { lines in
            _ = await calls.next()
            return lines.count
        }
        #expect(results.count == 3)
        #expect(await calls.value == 3)
    }

    @Test func smallInputIsOneRequest() async throws {
        let results = try await WholeRequest.run(lines: fakeLines(10), forceWindows: false) { $0.count }
        #expect(results == [10])
    }

    @Test func otherErrorsPropagate() async {
        await #expect(throws: LLMError.timedOut) {
            _ = try await WholeRequest.run(lines: fakeLines(10), forceWindows: false) { _ in throw LLMError.timedOut }
        }
    }
}

actor CallCounter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
