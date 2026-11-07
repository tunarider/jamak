import Testing
import Foundation
@testable import JamakCore

@MainActor
@Suite struct SubtitleDataEditorTests {
    struct Fixture {
        let editor: SubtitleDataEditor
        let setID: UUID
        let a: Cue
        let b: Cue
    }

    /// 자막셋 하나(ko 기본 + ja), 조각 둘. 티켓은 `tickets(setID, a, b)`로 만든다.
    func make(tickets: (UUID, Cue, Cue) -> [Ticket] = { _, _, _ in [] }) -> Fixture {
        var s = CueSet.initial(language: .ko)
        try! s.addLanguage(.ja)
        let a = Cue(start: 0, end: 1200, kind: .speech, texts: [.ko: "안녕", .ja: "やあ"])
        let b = Cue(start: 1000, end: 2000, kind: .speech, texts: [.ko: "잘가"])
        s.cues = [a, b]
        let book = TicketBook(tickets: tickets(s.id, a, b))
        let ed = SubtitleDataEditor(data: SubtitleData(sets: [s]), tickets: book)
        return Fixture(editor: ed, setID: s.id, a: a, b: b)
    }

    static func ticket(_ level: Ticket.Level, _ set: UUID, _ cue: UUID, _ language: Language,
                       before: String, after: String) -> Ticket {
        Ticket(setID: set, origin: .translation, language: language, level: level, reason: "이유",
               changes: [TicketChange(cueID: cue, before: before, after: after)])
    }

    /// 티켓이 있는 픽스처: a(ko) 의심+제안, a(ja) 의심(제안 없음), b(ko) 고침(잘 가 → 잘가).
    func makeMarked() -> Fixture {
        make { s, a, b in [
            Self.ticket(.suspect, s, a.id, .ko, before: "안녕", after: "안녕하세요"),
            Self.ticket(.suspect, s, a.id, .ja, before: "やあ", after: ""),
            Self.ticket(.fix, s, b.id, .ko, before: "잘 가", after: "잘가"),
        ] }
    }

    /// 변경 한 번이 undo 한 단계인지 본다(데이터와 티켓 함께).
    func expectOneStep(_ f: Fixture, _ name: String,
                       sourceLocation: SourceLocation = #_sourceLocation,
                       _ change: (SubtitleDataEditor) throws -> Void) rethrows {
        let ed = f.editor
        let before = (ed.data, ed.tickets)
        try change(ed)
        let after = (ed.data, ed.tickets)
        #expect(after != before, "\(name): 바뀐 것이 없다", sourceLocation: sourceLocation)
        #expect(ed.isDirty, "\(name)", sourceLocation: sourceLocation)
        ed.undoManager.undo()
        #expect(ed.data == before.0 && ed.tickets == before.1, "\(name): undo", sourceLocation: sourceLocation)
        #expect(!ed.undoManager.canUndo, "\(name): 한 단계가 아니다", sourceLocation: sourceLocation)
        #expect(!ed.isDirty, "\(name)", sourceLocation: sourceLocation)
        ed.undoManager.redo()
        #expect(ed.data == after.0 && ed.tickets == after.1, "\(name): redo", sourceLocation: sourceLocation)
        #expect(ed.isDirty, "\(name)", sourceLocation: sourceLocation)
    }

    @Test func deleteCuesOfKindRemovesTrackAndItsTicketsInOneStep() {
        let f = makeMarked()
        let screen = Cue(start: 3000, end: 4000, kind: .screen, texts: [.ko: "간판"])
        f.editor.addCue(screen, to: f.setID)
        f.editor.markSaved(); f.editor.clearHistory()
        expectOneStep(f, "deleteCues(ofKind:)") { [f] in
            #expect($0.deleteCues(ofKind: .speech, in: f.setID) == 2)
        }
        let set = f.editor.set(f.setID)!
        #expect(set.cues.map(\.id) == [screen.id])
        #expect(f.editor.tickets.tickets.isEmpty)
        #expect(f.editor.deleteCues(ofKind: .sound, in: f.setID) == 0)
    }

    @Test func everyMutationIsOneUndoStep() throws {
        var f = make()
        let fresh = Cue(start: 3000, end: 4000, kind: .sound, texts: [.ko: "[쾅]"])
        expectOneStep(f, "addCue") { [f] in $0.addCue(fresh, to: f.setID) }

        f = makeMarked()
        expectOneStep(f, "deleteCue") { [f] in $0.deleteCue(f.a.id, in: f.setID) }

        f = make()
        var moved = f.a; moved.start = 100; moved.kind = .screen
        expectOneStep(f, "updateTiming") { [f] in $0.updateTiming(moved, in: f.setID, actionName: "이동") }

        f = make()
        expectOneStep(f, "setText") { [f] in
            $0.setText("새 문장", cue: f.b.id, language: .ja, in: f.setID, actionName: "문장 수정")
        }

        f = makeMarked()
        let n1 = SubtitleClip(start: 0, end: 500, kind: .speech, text: "가")
        expectOneStep(f, "replaceCues") { [f] in
            $0.replaceCues(in: f.setID, removing: [f.a.id], adding: [n1], language: .ko, actionName: "구간 교체")
        }

        f = make()
        expectOneStep(f, "applyTexts") { [f] in
            $0.applyTexts([f.a.id: "おはよう", f.b.id: "さよなら"], language: .ja, in: f.setID, actionName: "번역")
        }

        f = make()
        let overlap = try #require(OverlapAnalyzer.speechOverlaps(
            f.editor.set(f.setID)!.view(language: .ko).clips).first)
        expectOneStep(f, "fixOverlap") { [f] in $0.fixOverlap(overlap, in: f.setID) }

        f = make()
        expectOneStep(f, "addSet") { [f] in _ = $0.addSet(name: "둘째", like: f.setID) }

        f = make()
        try expectOneStep(f, "duplicateSet") { [f] in _ = try $0.duplicateSet(f.setID, name: "복제") }

        f = makeMarked()
        let second = f.editor.addSet(name: "둘째", like: f.setID)
        f.editor.undoManager.removeAllActions()
        f.editor.markSaved()
        try expectOneStep(f, "deleteSet") { [f] in try $0.deleteSet(f.setID) }
        _ = second

        f = make()
        expectOneStep(f, "renameSet") { [f] in $0.renameSet(f.setID, to: "새 이름") }

        f = make()
        try expectOneStep(f, "addLanguage") { [f] in try $0.addLanguage(.en, to: f.setID) }

        f = makeMarked()
        try expectOneStep(f, "removeLanguage") { [f] in try $0.removeLanguage(.ja, original: .ko, from: f.setID) }

        f = make()
        expectOneStep(f, "open") { [f] in
            $0.open([Self.ticket(.fix, f.setID, f.a.id, .ko, before: "안녕", after: "안녕!")])
        }

        f = makeMarked()
        expectOneStep(f, "apply(ticket:)") { [f] in $0.apply(ticket: f.editor.tickets.tickets[0].id) }

        f = makeMarked()
        expectOneStep(f, "reject(ticket:)") { [f] in $0.reject(ticket: f.editor.tickets.tickets[2].id) }
    }

    @Test func openDropsFixThatWouldBlankCell() {
        let f = make()
        let opened = f.editor.open([Self.ticket(.fix, f.setID, f.a.id, .ko, before: "안녕", after: "")])
        #expect(opened.isEmpty)
        #expect(f.editor.tickets.tickets.isEmpty)
        #expect(f.editor.data.sets[0].cues.first { $0.id == f.a.id }?.text(.ko) == "안녕")
        // 제안 없는 의심은 그대로 연다.
        let suspect = f.editor.open([Self.ticket(.suspect, f.setID, f.a.id, .ko, before: "안녕", after: "")])
        #expect(suspect.count == 1)
    }

    @Test func openUsesGivenActionName() {
        let f = make()
        f.editor.open([Self.ticket(.fix, f.setID, f.a.id, .ko, before: "안녕", after: "안녕!")], actionName: "원문 검토")
        #expect(f.editor.undoManager.undoActionName == "원문 검토")
    }

    @Test func unchangedMutationsAreNoOps() throws {
        let f = makeMarked()
        let ed = f.editor
        let other = UUID()
        ed.setText("안녕", cue: f.a.id, language: .ko, in: f.setID, actionName: "x")
        ed.setText("x", cue: UUID(), language: .ko, in: f.setID, actionName: "x")
        ed.setText("x", cue: f.a.id, language: .en, in: f.setID, actionName: "x")  // 자막셋에 없는 언어
        ed.updateTiming(f.a, in: f.setID, actionName: "x")
        ed.addCue(f.a, to: f.setID)  // 이미 있는 id
        ed.addCue(Cue(start: 0, end: 1, kind: .speech), to: other)
        ed.deleteCue(UUID(), in: f.setID)
        ed.replaceCues(in: f.setID, removing: [UUID()], adding: [], language: .ko, actionName: "x")
        ed.applyTexts([f.a.id: "안녕"], language: .ko, in: f.setID, actionName: "x")
        ed.renameSet(f.setID, to: "기본")
        ed.renameSet(other, to: "x")
        try ed.changeOriginalLanguage(from: .ko, to: .ko)
        ed.open([])
        ed.open([Self.ticket(.suspect, f.setID, f.a.id, .ko, before: "안녕", after: "다른")])  // 이미 열린 칸
        ed.apply(ticket: UUID())
        ed.reject(ticket: UUID())
        ed.fixOverlap(Overlap(first: f.a.id, second: UUID(), start: 0, end: 0, isSuspect: true), in: f.setID)
        #expect(!ed.isDirty)
        #expect(!ed.undoManager.canUndo)
    }

    @Test func failingSetAndLanguageOpsThrowWithoutUndo() {
        let f = make()
        let ed = f.editor
        #expect(throws: SubtitleDataError.cannotDeleteLastSet) { try ed.deleteSet(f.setID) }
        #expect(throws: SubtitleDataError.setMissing) { try ed.deleteSet(UUID()) }
        #expect(throws: SubtitleDataError.setMissing) { try ed.duplicateSet(UUID(), name: "x") }
        #expect(throws: SubtitleDataError.languageExists) { try ed.addLanguage(.ja, to: f.setID) }
        #expect(throws: SubtitleDataError.setMissing) { try ed.addLanguage(.en, to: UUID()) }
        #expect(throws: SubtitleDataError.cannotRemoveOriginalLanguage) { try ed.removeLanguage(.ko, original: .ko, from: f.setID) }
        #expect(throws: SubtitleDataError.languageMissing) { try ed.removeLanguage(.en, original: .ko, from: f.setID) }
        #expect(throws: SubtitleDataError.originalLanguageLocked) { try ed.changeOriginalLanguage(from: .ko, to: .en) }
        #expect(!ed.isDirty)
        #expect(!ed.undoManager.canUndo)
    }

    @Test func removeLanguageUndoRestoresTextsAndTickets() throws {
        let f = makeMarked()
        let ed = f.editor
        let otherSet = ed.addSet(name: "둘째", like: f.setID)
        ed.addCue(Cue(start: 0, end: 900, kind: .speech, texts: [.ja: "別"]), to: otherSet)
        let otherCue = ed.set(otherSet)!.cues[0].id
        ed.open([Self.ticket(.suspect, otherSet, otherCue, .ja, before: "別", after: "")])
        let before = (ed.data, ed.tickets)

        try ed.removeLanguage(.ja, original: .ko, from: f.setID)
        let set = ed.set(f.setID)!
        #expect(set.languages == [.ko])
        #expect(set.cues.allSatisfy { $0.texts[.ja] == nil })
        #expect(!ed.tickets.tickets.contains { $0.setID == f.setID && $0.language == .ja })
        #expect(ed.tickets.tickets.count == 3)  // a(ko), b(ko), 둘째(ja)
        #expect(ed.set(otherSet)!.cues[0].texts == [.ja: "別"])
        #expect(ed.undoManager.undoActionName == "언어 삭제")

        ed.undoManager.undo()
        #expect(ed.data == before.0 && ed.tickets == before.1)
        #expect(ed.set(f.setID)!.cues[0].texts == [.ko: "안녕", .ja: "やあ"])
        ed.undoManager.redo()
        #expect(ed.set(f.setID)!.languages == [.ko])
        #expect(ed.tickets.tickets.count == 3)
    }

    @Test func deleteSetUndo() throws {
        let f = makeMarked()
        let ed = f.editor
        let second = ed.addSet(name: "둘째", like: f.setID)
        let before = (ed.data, ed.tickets)
        try ed.deleteSet(f.setID)
        #expect(ed.data.sets.map(\.id) == [second])
        #expect(ed.tickets.tickets.isEmpty)
        #expect(ed.undoManager.undoActionName == "자막셋 삭제")
        ed.undoManager.undo()
        #expect(ed.data == before.0 && ed.tickets == before.1)
        #expect(ed.data.sets.map(\.id) == [f.setID, second])
        ed.undoManager.undo()  // addSet
        #expect(ed.data.sets.map(\.id) == [f.setID])
        #expect(!ed.isDirty)
    }

    @Test func applySuspectUndoRestoresTicket() {
        let f = makeMarked()
        let ed = f.editor
        let ticket = ed.tickets.tickets[0]
        ed.apply(ticket: ticket.id)
        #expect(ed.set(f.setID)!.cues[0].text(.ko) == "안녕하세요")
        #expect(!ed.tickets.tickets.contains { $0.id == ticket.id })
        #expect(ed.tickets.tickets.count == 2)
        ed.undoManager.undo()
        #expect(ed.set(f.setID)!.cues[0].text(.ko) == "안녕")
        #expect(ed.tickets.tickets.contains(ticket))
        #expect(!ed.undoManager.canUndo)
        #expect(!ed.isDirty)
    }

    @Test func rejectFixRestoresBeforeText() {
        let f = makeMarked()
        let ed = f.editor
        let ticket = ed.tickets.tickets[2]
        ed.reject(ticket: ticket.id)
        #expect(ed.set(f.setID)!.cues[1].text(.ko) == "잘 가")
        #expect(!ed.tickets.tickets.contains(ticket))
        ed.undoManager.undo()
        #expect(ed.set(f.setID)!.cues[1].text(.ko) == "잘가")
        #expect(ed.tickets.tickets.contains(ticket))
    }

    @Test func deleteCueRemovesItsTicketsInAllLanguages() {
        let f = makeMarked()
        let ed = f.editor
        ed.deleteCue(f.a.id, in: f.setID)
        #expect(ed.set(f.setID)!.cues.map(\.id) == [f.b.id])
        #expect(ed.tickets.tickets.flatMap(\.cueIDs) == [f.b.id])
        ed.undoManager.undo()
        #expect(ed.set(f.setID)!.cues.map(\.id) == [f.a.id, f.b.id])
        #expect(ed.tickets.tickets.count == 3)
    }

    @Test func revisionChangesOnEditAndReturnsOnUndo() {
        let f = make()
        let ed = f.editor
        let start = ed.revision
        ed.renameSet(f.setID, to: "기본")   // 같은 이름: 바뀌지 않는다
        #expect(ed.revision == start)
        ed.open([Self.ticket(.suspect, f.setID, f.a.id, .ko, before: "안녕", after: "")])
        let marked = ed.revision
        #expect(marked != start)
        ed.undoManager.undo()
        #expect(ed.revision == start)
        ed.undoManager.redo()
        #expect(ed.revision == marked)
    }

    @Test func clearHistoryKeepsDataAndSavedState() {
        let f = make()
        let ed = f.editor
        ed.setText("새 문장", cue: f.a.id, language: .ko, in: f.setID, actionName: "문장 수정")
        ed.open([Self.ticket(.suspect, f.setID, f.b.id, .ko, before: "잘가", after: "")])
        ed.markSaved()
        let data = ed.data, tickets = ed.tickets
        ed.clearHistory()
        #expect(!ed.undoManager.canUndo && !ed.undoManager.canRedo)
        #expect(ed.data == data && ed.tickets == tickets)
        #expect(!ed.isDirty)
        // 지운 뒤의 편집은 다시 한 단계로 남고, 되돌리면 저장된 상태다.
        ed.setText("또", cue: f.a.id, language: .ko, in: f.setID, actionName: "문장 수정")
        #expect(ed.isDirty)
        ed.undoManager.undo()
        #expect(!ed.isDirty && ed.data == data)
        #expect(!ed.undoManager.canUndo)
    }

    @Test func clearHistoryDropsRedoAndKeepsDirtyWhenUnsaved() {
        let f = make()
        let ed = f.editor
        ed.setText("x", cue: f.a.id, language: .ko, in: f.setID, actionName: "문장 수정")
        ed.setText("y", cue: f.a.id, language: .ko, in: f.setID, actionName: "문장 수정")
        ed.undoManager.undo()
        #expect(ed.undoManager.canRedo)
        ed.clearHistory()
        #expect(!ed.undoManager.canUndo && !ed.undoManager.canRedo)
        #expect(ed.isDirty)
        #expect(ed.data.set(id: f.setID)?.cues.first { $0.id == f.a.id }?.text(.ko) == "x")
    }

    @Test func dirtyTracksSavedVersion() {
        let f = make()
        let ed = f.editor
        #expect(!ed.isDirty)
        ed.setText("하나", cue: f.a.id, language: .ko, in: f.setID, actionName: "수정")
        ed.markSaved()
        #expect(!ed.isDirty)
        ed.setText("둘", cue: f.a.id, language: .ko, in: f.setID, actionName: "수정")
        #expect(ed.isDirty)
        ed.undoManager.undo()
        #expect(!ed.isDirty)
        ed.undoManager.undo()
        #expect(ed.isDirty)
        ed.undoManager.redo()
        #expect(!ed.isDirty)
        // 저장 지점 뒤로 되돌린 다음 새로 고치면 다시 저장 지점으로 갈 수 없다.
        ed.undoManager.undo()
        ed.setText("셋", cue: f.a.id, language: .ko, in: f.setID, actionName: "수정")
        #expect(ed.isDirty)
        ed.undoManager.undo()
        #expect(ed.isDirty)
    }

    @Test func replaceCuesKeepsOtherLanguages() {
        let f = makeMarked()
        let ed = f.editor
        // b는 같은 id로 다시 들어온다(시간·ja 문장만 바뀌고 ko는 남는다). a는 지워지고, 새 조각이 들어온다.
        let bAgain = SubtitleClip(id: f.b.id, start: 1100, end: 2100, kind: .speech, text: "またね")
        let fresh = SubtitleClip(start: 300, end: 900, kind: .speech, text: "新しい")
        ed.replaceCues(in: f.setID, removing: [f.a.id], adding: [bAgain, fresh], language: .ja,
                       actionName: "구간 교체")
        let cues = ed.set(f.setID)!.cues
        #expect(cues.map(\.id) == [fresh.id, f.b.id])
        #expect(cues[1].texts == [.ko: "잘가", .ja: "またね"])
        #expect(cues[1].start == 1100 && cues[1].end == 2100)
        #expect(cues[0].texts == [.ja: "新しい"])
        // 지운 조각의 티켓은 사라지고, 남은 조각(b)의 ko 티켓은 그대로다(ko 칸은 바뀌지 않았다).
        #expect(ed.tickets.tickets.flatMap(\.cueIDs) == [f.b.id])
        #expect(ed.undoManager.undoActionName == "구간 교체")
        ed.undoManager.undo()
        #expect(ed.set(f.setID)!.cues == [f.a, f.b])
        #expect(ed.tickets.tickets.count == 3)
    }

    @Test func replaceCuesOverlapIsUpdateKeepingOtherLanguageTickets() {
        let f = makeMarked()
        let ed = f.editor
        let aAgain = SubtitleClip(id: f.a.id, start: 0, end: 1000, kind: .speech, text: "こんにちは")
        ed.replaceCues(in: f.setID, removing: [f.a.id, f.b.id], adding: [aAgain], language: .ja,
                       actionName: "구간 교체")
        let cues = ed.set(f.setID)!.cues
        #expect(cues.map(\.id) == [f.a.id])
        #expect(cues[0].texts == [.ko: "안녕", .ja: "こんにちは"])
        #expect(cues[0].end == 1000)
        // a의 ko 티켓은 남고, 문장이 바뀐 a의 ja 칸 티켓과 정말 지운 b의 티켓은 사라진다.
        #expect(ed.tickets.tickets.map(\.cueIDs) == [[f.a.id]])
        #expect(ed.tickets.tickets.first?.language == .ko)
    }

    @Test func cellWritesReportMissingSetOrLanguage() {
        let f = make()
        let ed = f.editor
        #expect(!ed.setText("x", cue: f.a.id, language: .en, in: f.setID, actionName: "x"))
        #expect(!ed.setText("x", cue: f.a.id, language: .ko, in: UUID(), actionName: "x"))
        #expect(!ed.applyTexts([f.a.id: "x"], language: .en, in: f.setID, actionName: "x"))
        #expect(!ed.applyTexts([f.a.id: "x"], language: .ko, in: UUID(), actionName: "x"))
        #expect(!ed.replaceCues(in: f.setID, removing: [], adding: [], language: .en, actionName: "x"))
        #expect(!ed.replaceCues(in: UUID(), removing: [], adding: [], language: .ko, actionName: "x"))
        #expect(!ed.undoManager.canUndo)
        #expect(ed.setText("안녕", cue: f.a.id, language: .ko, in: f.setID, actionName: "x"))  // 같은 값: true, 단계 없음
        #expect(ed.applyTexts([f.a.id: "x"], language: .ja, in: f.setID, actionName: "x"))
        #expect(ed.undoManager.canUndo)
    }

    @Test func addCueKeepsTimelineOrder() {
        let f = make()
        let ed = f.editor
        let mid = Cue(start: 500, end: 700, kind: .screen, texts: [.ko: "가운데"])
        ed.addCue(mid, to: f.setID)
        #expect(ed.set(f.setID)!.cues.map(\.id) == [f.a.id, mid.id, f.b.id])
    }

    @Test func updateTimingKeepsTexts() {
        let f = make()
        let ed = f.editor
        var moved = f.a
        moved.start = 200; moved.end = 900
        moved.texts = [:]
        ed.updateTiming(moved, in: f.setID, actionName: "조각 이동")
        let cue = ed.set(f.setID)!.cues[0]
        #expect(cue.start == 200 && cue.end == 900 && cue.texts == f.a.texts)
        #expect(ed.undoManager.undoActionName == "조각 이동")
    }

    @Test func fixOverlapSnapsEarlierEnd() {
        let f = make()
        let ed = f.editor
        let o = OverlapAnalyzer.speechOverlaps(ed.set(f.setID)!.view(language: .ko).clips)[0]
        ed.fixOverlap(o, in: f.setID)
        #expect(ed.set(f.setID)!.cues[0].end == 1000)
        #expect(ed.undoManager.undoActionName == "싱크 맞추기")
    }

    @Test func applyTextsClosesTicketsOfChangedCells() {
        let f = makeMarked()
        let ed = f.editor
        ed.applyTexts([f.a.id: "안녕!", f.b.id: "잘가"], language: .ko, in: f.setID, actionName: "교정")
        #expect(ed.set(f.setID)!.cues[0].text(.ko) == "안녕!")
        // a(ko)는 바뀌어 티켓이 닫히고, 같은 문장인 b(ko)와 다른 언어 a(ja)는 남는다.
        #expect(ed.tickets.tickets.map(\.language) == [.ja, .ko])
        ed.undoManager.undo()
        #expect(ed.set(f.setID)!.cues[0].text(.ko) == "안녕")
        #expect(ed.tickets.tickets.count == 3)
        #expect(!ed.undoManager.canUndo)
    }

    @Test func duplicateSetCopiesCuesButNotTickets() throws {
        let f = makeMarked()
        let ed = f.editor
        let copy = try ed.duplicateSet(f.setID, name: "복제")
        let set = try #require(ed.set(copy))
        #expect(set.name == "복제" && set.cues.count == 2)
        #expect(Set(set.cues.map(\.id)).isDisjoint(with: [f.a.id, f.b.id]))
        #expect(ed.tickets.tickets.allSatisfy { $0.setID == f.setID })
    }

    @Test func historyIsSharedAcrossSets() throws {
        let f = make()
        let ed = f.editor
        let second = ed.addSet(name: "둘째", like: f.setID)
        ed.addCue(Cue(start: 0, end: 500, kind: .speech, texts: [.ko: "가"]), to: second)
        ed.setText("바뀜", cue: f.a.id, language: .ko, in: f.setID, actionName: "수정")
        ed.undoManager.undo()
        ed.undoManager.undo()
        ed.undoManager.undo()
        #expect(ed.data.sets.count == 1)
        #expect(!ed.undoManager.canUndo)
    }

    @Test func undoHistoryIsBounded() {
        #expect(make().editor.undoManager.levelsOfUndo == 200)
    }

    @Test func updateTimingKeepsTimelineOrderAndLaterNoOpWriteLeavesNoStep() {
        let f = make()
        // a(0–1200)를 b(1000–2000) 뒤로 옮긴다: 저장 순서도 타임라인 순서를 따른다.
        var moved = f.a
        moved.start = 3000; moved.end = 4000
        f.editor.updateTiming(moved, in: f.setID, actionName: "시간")
        let cues = f.editor.set(f.setID)!.cues
        #expect(cues.map(\.id) == [f.b.id, f.a.id])
        #expect(cues == cues.sorted(by: Cue.timelineOrder))
        // 그 뒤 아무것도 바꾸지 않는 되쓰기(같은 문장 가져오기 등)는 순서를 몰래 바꾸며 단계를 남기지 않는다.
        f.editor.undoManager.removeAllActions()
        let same = CueWrite(language: .ko, texts: [f.a.id: "안녕"])
        f.editor.apply(same, to: f.setID, actionName: "가져오기")
        #expect(!f.editor.undoManager.canUndo)
        // 실행 취소하면 원래 순서로 돌아온다.
        let g = make()
        g.editor.updateTiming(moved, in: g.setID, actionName: "시간")
        g.editor.undoManager.undo()
        #expect(g.editor.set(g.setID)!.cues.map(\.id) == [g.a.id, g.b.id])
    }

    @Test func changedSetsListsSetsWhoseContentOrTicketsDiffer() {
        let f = make()
        let before = (f.editor.data, f.editor.tickets)
        #expect(SubtitleDataEditor.changedSets(from: before.0, before.1, to: before.0, before.1).isEmpty)
        // 문장만 바꿈.
        f.editor.setText("새", cue: f.a.id, language: .ko, in: f.setID, actionName: "x")
        #expect(SubtitleDataEditor.changedSets(from: before.0, before.1, to: f.editor.data, f.editor.tickets) == [f.setID])
        // 티켓만 바꿈.
        let tickets = TicketBook(tickets: [Self.ticket(.suspect, f.setID, f.a.id, .ko, before: "안녕", after: "")])
        #expect(SubtitleDataEditor.changedSets(from: before.0, before.1, to: before.0, tickets) == [f.setID])
        // 자막셋 더하기와 지우기(실행 취소 방향 모두).
        let added = f.editor.addSet(name: "둘", like: f.setID)
        let after = f.editor.data
        #expect(SubtitleDataEditor.changedSets(from: before.0, before.1, to: after, f.editor.tickets) == [f.setID, added])
        #expect(SubtitleDataEditor.changedSets(from: after, f.editor.tickets, to: before.0, before.1) == [f.setID, added])
        // 다른 자막셋의 티켓은 그 자막셋으로 센다.
        let other = TicketBook(tickets: [Self.ticket(.suspect, added, f.a.id, .ko, before: "안녕", after: "")])
        #expect(SubtitleDataEditor.changedSets(from: after, TicketBook(), to: after, other) == [added])
    }
}
