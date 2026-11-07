import Foundation
import Testing
@testable import JamakCore

/// 조각의 검토됨·주석, 원문 티켓의 뜻 풀이.
@MainActor
@Suite struct ReviewedNoteTests {
    func makeSet() -> CueSet {
        var s = CueSet.initial(language: .ja)
        try! s.addLanguage(.ko)
        s.cues = (0..<4).map { i in
            Cue(start: i * 1000, end: i * 1000 + 900, kind: .speech, texts: [.ja: "원\(i)", .ko: "번\(i)"])
        }
        return s
    }

    func editor(_ s: CueSet, tickets: [Ticket] = []) -> SubtitleDataEditor {
        SubtitleDataEditor(data: SubtitleData(sets: [s]), tickets: TicketBook(tickets: tickets), original: .ja)
    }

    // MARK: 저장 형식

    @Test func cueRoundTripsReviewedAndNote() throws {
        let cue = Cue(start: 0, end: 900, kind: .speech, texts: [.ja: "a"], reviewed: [.ja, .ko], note: "명령형이 맞음")
        let back = try JSONDecoder().decode(Cue.self, from: JSONEncoder().encode(cue))
        #expect(back == cue)
    }

    @Test func emptyReviewedAndNoteAreNotWritten() throws {
        let raw = String(decoding: try JSONEncoder().encode(Cue(start: 0, end: 900, kind: .speech, texts: [.ja: "a"])),
                         as: UTF8.self)
        #expect(!raw.contains("reviewed") && !raw.contains("note"))
        let old = #"{"id":"\#(UUID().uuidString)","start":0,"end":1,"kind":"speech","texts":{"ja":"a"}}"#
        let cue = try JSONDecoder().decode(Cue.self, from: Data(old.utf8))
        #expect(cue.reviewed.isEmpty && cue.note.isEmpty)
    }

    @Test func ticketChangeMeaningsRoundTrip() throws {
        let change = TicketChange(cueID: UUID(), before: "おごるよ", after: "おごれよ",
                                  meaningBefore: "내가 살게", meaningAfter: "네가 사")
        #expect(try JSONDecoder().decode(TicketChange.self, from: JSONEncoder().encode(change)) == change)
        let plain = String(decoding: try JSONEncoder().encode(TicketChange(cueID: UUID(), before: "a", after: "b")),
                           as: UTF8.self)
        #expect(!plain.contains("meaning"))
    }

    // MARK: 편집 규칙

    @Test func resolvingTicketMarksReviewedAndAppendsNote() {
        let s = makeSet()
        let c = s.cues
        let fix = Ticket(setID: s.id, origin: .source, language: .ja, level: .suspect, reason: "이상해요",
                         changes: [TicketChange(cueID: c[0].id, before: "원0", after: "고친0"),
                                   TicketChange(cueID: c[1].id, before: "원1", after: "")])
        let keep = Ticket(setID: s.id, origin: .translation, language: .ko, level: .suspect, reason: "어색해요",
                          changes: [TicketChange(cueID: c[2].id, before: "번2", after: "")])
        var noted = s
        noted.cues[0].note = "앞 주석"
        let ed = editor(noted, tickets: [fix, keep])

        ed.apply(ticket: fix.id, note: "  명령형이 맞음 ")
        var now = ed.set(s.id)!.cues
        #expect(now[0].text(.ja) == "고친0")
        // 원문이 바뀌어 그 조각의 검토됨은 정리된 뒤 원문 칸이 검토됨이 된다.
        #expect(now[0].reviewed == [.ja] && now[1].reviewed == [.ja])
        #expect(now[0].note == "앞 주석\n명령형이 맞음" && now[1].note == "명령형이 맞음")

        ed.reject(ticket: keep.id)
        now = ed.set(s.id)!.cues
        #expect(now[2].reviewed == [.ko] && now[2].note.isEmpty)

        ed.undoManager.undo()
        #expect(ed.set(s.id)!.cues[2].reviewed.isEmpty)
    }

    @Test func textChangeClearsReviewed() {
        var s = makeSet()
        for i in s.cues.indices { s.cues[i].reviewed = [.ja, .ko] }
        let ed = editor(s)
        let c = s.cues
        // 번역 칸이 바뀌면 그 칸만 풀린다.
        ed.setText("새 번역", cue: c[0].id, language: .ko, in: s.id, actionName: "고치기")
        #expect(ed.set(s.id)!.cues[0].reviewed == [.ja])
        // 원문 칸이 바뀌면 모두 풀린다.
        ed.setText("새 원문", cue: c[1].id, language: .ja, in: s.id, actionName: "고치기")
        #expect(ed.set(s.id)!.cues[1].reviewed.isEmpty)
        // 시간만 바꾸면 그대로다.
        var moved = c[2]
        moved.start += 10
        ed.updateTiming(moved, in: s.id, actionName: "옮기기")
        #expect(ed.set(s.id)!.cues[2].reviewed == [.ja, .ko])
    }

    @Test func openingFixTicketClearsReviewed() {
        var s = makeSet()
        s.cues[0].reviewed = [.ja, .ko]
        let ed = editor(s)
        let fix = Ticket(setID: s.id, origin: .translation, language: .ko, level: .fix, reason: "틀려요",
                         changes: [TicketChange(cueID: s.cues[0].id, before: "번0", after: "고친 번역")])
        ed.open([fix])
        #expect(ed.set(s.id)!.cues[0].reviewed == [.ja])
    }

    @Test func setNoteAndReviewedAreUndoable() {
        let s = makeSet()
        let ed = editor(s)
        let id = s.cues[0].id
        ed.setNote("  확인함 \n", cue: id, in: s.id)
        ed.setReviewed(true, cue: id, language: .ko, in: s.id)
        #expect(ed.set(s.id)!.cues[0].note == "확인함")
        #expect(ed.set(s.id)!.cues[0].reviewed == [.ko])
        // 주석은 검토됨을 풀지 않는다.
        ed.setNote("다시", cue: id, in: s.id)
        #expect(ed.set(s.id)!.cues[0].reviewed == [.ko])
        ed.setReviewed(false, cue: id, language: .ko, in: s.id)
        #expect(ed.set(s.id)!.cues[0].reviewed.isEmpty)
        ed.undoManager.undo()
        ed.undoManager.undo()
        #expect(ed.set(s.id)!.cues[0].note == "확인함" && ed.set(s.id)!.cues[0].reviewed == [.ko])
    }

    @Test func appendNoteIsOneStep() {
        var s = makeSet()
        s.cues[0].note = "앞"
        let ed = editor(s)
        ed.appendNote("  뒤 ", cues: [s.cues[0].id, s.cues[1].id], in: s.id)
        #expect(ed.set(s.id)!.cues[0].note == "앞\n뒤" && ed.set(s.id)!.cues[1].note == "뒤")
        ed.appendNote("   ", cues: [s.cues[0].id], in: s.id)
        ed.undoManager.undo()
        #expect(ed.set(s.id)!.cues[0].note == "앞" && ed.set(s.id)!.cues[1].note.isEmpty)
    }

    @Test func rangeWriteCarriesNotes() {
        var s = makeSet()
        s.cues[0].note = "첫 주석"
        s.cues[1].note = "둘째 주석"
        // 두 조각이 결과 하나로 모인다.
        let result = SubtitleClip(id: UUID(), start: 0, end: 1900, kind: .speech, text: "합친 원문")
        let write = RangeWrite.replacing([s.cues[0].id, s.cues[1].id], with: [result], language: .ja, in: s)
        let ed = editor(s)
        ed.apply(write, to: s.id, actionName: "다시 받아쓰기")
        let merged = ed.set(s.id)!.cues.first { $0.id == result.id }
        #expect(merged?.note == "첫 주석\n둘째 주석")
        // 한 조각이 한 결과로 바뀌면 같은 조각이라 주석이 남는다.
        let one = SubtitleClip(id: UUID(), start: 2000, end: 2900, kind: .speech, text: "새 원문")
        let target = ed.set(s.id)!.cues.first { $0.start == 2000 }!
        ed.setNote("셋째", cue: target.id, in: s.id)
        ed.apply(RangeWrite.replacing([target.id], with: [one], language: .ja, in: ed.set(s.id)!),
                 to: s.id, actionName: "다시 받아쓰기")
        #expect(ed.set(s.id)!.cues.first { $0.start == 2000 }?.note == "셋째")
        #expect(RangeWrite.losesOtherLanguages([target.id], in: ed.set(s.id)!, original: .ja))
    }

    @Test func dropsCarriedWhenNoSameKindResult() {
        var s = makeSet()
        s.cues[0].kind = .sound
        s.cues[0].note = "주석"
        let speech = SubtitleClip(id: UUID(), start: 0, end: 900, kind: .speech, text: "대사")
        #expect(RangeWrite.dropsCarried([s.cues[0].id], results: [speech], in: s, original: .ja))
        let sound = SubtitleClip(id: UUID(), start: 0, end: 900, kind: .sound, text: "(소리)")
        #expect(!RangeWrite.dropsCarried([s.cues[0].id], results: [sound], in: s, original: .ja))
    }

    @Test func removingLanguageClearsItsReviewed() throws {
        var s = makeSet()
        s.cues[0].reviewed = [.ja, .ko]
        try s.removeLanguage(.ko, original: .ja)
        #expect(s.cues[0].reviewed == [.ja])
    }

    @Test func clipRetranscriptionOnlyClipKeepsOverlaps() {
        let a = SubtitleClip(id: UUID(), start: 1000, end: 3000, kind: .speech, text: "a")
        let b = SubtitleClip(id: UUID(), start: 2000, end: 4000, kind: .speech, text: "b")
        let wide = RangeJobPlan.clipRetranscription(clip: a, clips: [a, b], durationMs: 10_000)
        let only = RangeJobPlan.clipRetranscription(clip: a, clips: [a, b], durationMs: 10_000, onlyClip: true)
        #expect(wide.targets == [a.id, b.id])
        #expect(only.targets == [a.id])
    }

    @Test func wholeRequestSkipsWindowsWithoutTargets() async throws {
        var lines = (1...20).map { LLMLine(id: "\($0)", time: "", kind: "speech", source: "s") }
        for i in 0..<10 { lines[i].context = true }
        let sent = try await WholeRequest.run(lines: lines, window: 5, overlap: 0, forceWindows: true) { $0.map(\.id) }
        #expect(sent.count == 2)
        #expect(sent.first?.first == "11")
    }

    // MARK: 검토

    func body(_ request: ChatRequest) -> String {
        request.messages.flatMap(\.parts).compactMap { part -> String? in
            if case .text(let s) = part { return s } else { return nil }
        }.joined(separator: "\n")
    }

    func line(_ id: String, in prompt: String) -> String? {
        prompt.components(separatedBy: "\n").first { $0.hasPrefix("{") && $0.contains("\"kind\":") && $0.contains("\"id\":\"\(id)\"") }
    }

    @Test func wholeReviewSkipsReviewedCellsAsContext() async throws {
        var s = makeSet()
        s.cues[1].reviewed = [.ja]
        s.cues[2].reviewed = [.ko]
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"suspect","reason":"a","changes":[{"id":"2","text":"x"}]},
          {"level":"suspect","reason":"b","changes":[{"id":"3","text":"y"}]}
        ]}
        """#])
        let tickets = try await ReviewPipeline.run(
            kind: .source, set: s, original: .ja, targets: nil, notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false,
            skipReviewed: true)
        let prompt = body(chat.requests[0])
        #expect(line("2", in: prompt)?.contains("\"context\":true") == true)
        #expect(line("3", in: prompt)?.contains("\"context\"") == false)
        // 원문 칸이 검토됨인 2번 티켓은 버린다. 3번은 번역 칸만 검토됨이라 원문 검토 대상이다.
        #expect(tickets.map { $0.changes[0].cueID } == [s.cues[2].id])
    }

    @Test func clipReviewIgnoresReviewed() async throws {
        var s = makeSet()
        s.cues[1].reviewed = [.ja]
        let chat = FakeChat(replies: [#"{"tickets":[{"level":"suspect","reason":"a","changes":[{"id":"2","text":"x"}]}]}"#])
        let tickets = try await ReviewPipeline.run(
            kind: .source, set: s, original: .ja, targets: [s.cues[1].id], notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false)
        #expect(tickets.count == 1)
    }

    @Test func rangeReviewWithOnlyReviewedTargetsSendsNothing() async throws {
        var s = makeSet()
        s.cues[1].reviewed = [.ko]
        let chat = FakeChat(replies: [])
        let tickets = try await ReviewPipeline.run(
            kind: .translation(.ko), set: s, original: .ja, targets: [s.cues[1].id],
            notes: NotesDocument(markdown: ""), tickets: TicketBook(), guide: nil,
            text: LLMRole(client: chat, model: "m"), forceWindows: false, skipReviewed: true)
        #expect(tickets.isEmpty && chat.requests.isEmpty)
    }

    @Test func notesGoIntoLines() async throws {
        var s = makeSet()
        s.cues[0].note = " 명령형이 맞음 "
        let chat = FakeChat(replies: [#"{"tickets":[]}"#])
        _ = try await ReviewPipeline.run(
            kind: .source, set: s, original: .ja, targets: nil, notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false)
        let prompt = body(chat.requests[0])
        #expect(line("1", in: prompt)?.contains("\"note\":\"명령형이 맞음\"") == true)
        #expect(line("2", in: prompt)?.contains("note") == false)
    }

    @Test func sourceTicketsCarryMeaningsInUserLanguage() async throws {
        let s = makeSet()
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"fix","reason":"a","changes":[{"id":"1","text":"고친0","meaningBefore":" 원래 뜻 ","meaningAfter":"바뀐 뜻"}]},
          {"level":"suspect","reason":"b","changes":[{"id":"2","text":"","meaningBefore":"뜻","meaningAfter":"버릴 뜻"}]}
        ]}
        """#])
        let tickets = try await ReviewPipeline.run(
            kind: .source, set: s, original: .ja, targets: nil, notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false,
            userLanguage: .ko)
        let prompt = body(chat.requests[0])
        #expect(prompt.contains("meaningBefore") && prompt.contains("한국어"))
        #expect(tickets[0].changes[0].meaningBefore == "원래 뜻" && tickets[0].changes[0].meaningAfter == "바뀐 뜻")
        // 제안이 없으면 바뀐 뜻은 버린다.
        #expect(tickets[1].changes[0].meaningBefore == "뜻" && tickets[1].changes[0].meaningAfter.isEmpty)
    }

    @Test func noMeaningsWhenUserLanguageIsOriginal() async throws {
        let s = makeSet()
        let chat = FakeChat(replies: [#"""
        {"tickets":[{"level":"fix","reason":"a","changes":[{"id":"1","text":"고친0","meaningBefore":"x","meaningAfter":"y"}]}]}
        """#])
        let tickets = try await ReviewPipeline.run(
            kind: .source, set: s, original: .ja, targets: nil, notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false,
            userLanguage: .ja)
        #expect(!body(chat.requests[0]).contains("meaningBefore"))
        #expect(!body(chat.requests[0]).contains("{{"))
        #expect(tickets[0].changes[0].meaningBefore.isEmpty)
    }

    @Test func translationReviewAsksNoMeaningsAndNoSourceTickets() async throws {
        let s = makeSet()
        let chat = FakeChat(replies: [#"""
        {"tickets":[
          {"level":"fix","reason":"a","target":"source","changes":[{"id":"1","text":"고친0","meaningBefore":"전","meaningAfter":"후"}]},
          {"level":"fix","reason":"b","target":"translation","changes":[{"id":"2","text":"고친 번역","meaningBefore":"x","meaningAfter":"y"}]}
        ]}
        """#])
        let tickets = try await ReviewPipeline.run(
            kind: .translation(.ko), set: s, original: .ja, targets: nil, notes: NotesDocument(markdown: ""),
            tickets: TicketBook(), guide: nil, text: LLMRole(client: chat, model: "m"), forceWindows: false,
            userLanguage: .ko)
        #expect(tickets.count == 1)
        #expect(tickets[0].language == .ko && tickets[0].changes[0].meaningBefore.isEmpty)
        #expect(!body(chat.requests[0]).contains("meaningBefore"))
        #expect(!body(chat.requests[0]).contains("{{"))
    }
}
