import Testing
import Foundation
@testable import JamakCore

@MainActor
@Suite struct SceneMemoTests {
    func memo(_ start: Int, _ end: Int, _ text: String = "메모") -> SceneMemo {
        SceneMemo(start: start, end: end, text: text)
    }

    @Test func memoEditsAreOneUndoStep() {
        let helper = SubtitleDataEditorTests()
        let f = helper.make()
        let m = memo(0, 1000, "비 오는 밤")
        helper.expectOneStep(f, "addMemo") { [f] in $0.addMemo(m, to: f.setID) }
        #expect(f.editor.set(f.setID)!.memos == [m])
        f.editor.markSaved(); f.editor.clearHistory()

        var edited = m
        edited.end = 2000
        edited.text = "비가 그친다"
        helper.expectOneStep(f, "updateMemo") { [f] in $0.updateMemo(edited, in: f.setID, actionName: "메모 수정") }
        #expect(f.editor.set(f.setID)!.memos == [edited])
        f.editor.markSaved(); f.editor.clearHistory()

        helper.expectOneStep(f, "deleteMemo") { [f] in $0.deleteMemo(m.id, in: f.setID) }
        #expect(f.editor.set(f.setID)!.memos.isEmpty)

        f.editor.addMemo(memo(0, 10), to: f.setID)
        f.editor.addMemo(memo(20, 30), to: f.setID)
        f.editor.markSaved(); f.editor.clearHistory()
        helper.expectOneStep(f, "clearMemos") { [f] in #expect($0.clearMemos(in: f.setID) == 2) }
        #expect(f.editor.clearMemos(in: f.setID) == 0)
    }

    @Test func memosStayInStartOrder() {
        let f = SubtitleDataEditorTests().make()
        let late = memo(5000, 6000), early = memo(0, 1000)
        f.editor.addMemo(late, to: f.setID)
        f.editor.addMemo(early, to: f.setID)
        #expect(f.editor.set(f.setID)!.memos.map(\.id) == [early.id, late.id])
        var moved = early
        moved.start = 7000; moved.end = 8000
        f.editor.updateMemo(moved, in: f.setID, actionName: "메모 수정")
        #expect(f.editor.set(f.setID)!.memos.map(\.id) == [late.id, early.id])
    }

    @Test func duplicateCopiesMemosWithNewIDs() throws {
        let f = SubtitleDataEditorTests().make()
        f.editor.addMemo(memo(0, 1000, "가"), to: f.setID)
        let newID = try f.editor.duplicateSet(f.setID, name: "복제")
        let original = f.editor.set(f.setID)!.memos
        let copy = f.editor.set(newID)!.memos
        #expect(copy.count == 1)
        #expect(copy[0].id != original[0].id)
        #expect(copy[0].start == 0 && copy[0].end == 1000 && copy[0].text == "가")
    }

    @Test func cueEditsKeepMemos() {
        let f = SubtitleDataEditorTests().make()
        f.editor.addMemo(memo(0, 1000), to: f.setID)
        f.editor.addMemo(memo(2000, 3000), to: f.setID)
        f.editor.deleteCues(ofKind: .speech, in: f.setID)
        #expect(f.editor.set(f.setID)!.memos.count == 2)
        let clip = SubtitleClip(id: UUID(), start: 0, end: 500, kind: .speech, text: "새")
        f.editor.replaceCues(in: f.setID, removing: [], adding: [clip], language: .ko, actionName: "교체")
        #expect(f.editor.set(f.setID)!.cues.count == 1)
        #expect(f.editor.set(f.setID)!.memos.count == 2)
    }

    @Test func overlappingMemos() {
        let a = memo(0, 1000), b = memo(900, 2000), c = memo(3000, 4000)
        let set = CueSet(name: "x", languages: [.ko], memos: [a, b, c])
        #expect(set.memos(overlapping: 900...1500).map(\.id) == [a.id, b.id])
    }

    @Test func changeOriginalLanguageAllowedWithOnlyMemos() throws {
        var data = SubtitleData(sets: [CueSet(name: "a", languages: [.ja], memos: [memo(0, 1000)])])
        try data.changeOriginalLanguage(from: .ja, to: .ko)
        #expect(data.sets[0].languages == [.ko])
        #expect(data.sets[0].memos.count == 1)
    }

    @Test func memosAreRequiredInJSON() throws {
        let set = CueSet(name: "x", languages: [.ko], memos: [memo(0, 1)])
        let back = try JSONDecoder().decode(CueSet.self, from: JSONEncoder().encode(set))
        #expect(back == set)
        let json = #"{"id":"\#(UUID().uuidString)","name":"x","languages":["ko"],"cues":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CueSet.self, from: Data(json.utf8)) }
    }
}
