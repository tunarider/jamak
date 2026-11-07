import Testing
import Foundation
@testable import JamakCore

struct OriginalLanguageTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func originalLanguageIsSavedOnCreate() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let video = base.appendingPathComponent("v.mp4")
        try Data(count: 10).write(to: video)
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let p = try store.createProject(video: video, durationMs: 1000, bookmark: Data(), language: .ja)
        #expect(p.state.originalLanguage == .ja)
        #expect(p.subtitles.sets[0].languages == [.ja])
        let loaded = try store.load(try #require(try store.list().first))
        #expect(loaded.state.originalLanguage == .ja)
    }

    @Test func cannotRemoveOriginalLanguage() {
        var set = CueSet(name: "기본", languages: [.ja, .ko])
        #expect(throws: SubtitleDataError.cannotRemoveOriginalLanguage) { try set.removeLanguage(.ja, original: .ja) }
        #expect(throws: Never.self) { try set.removeLanguage(.ko, original: .ja) }
        #expect(set.languages == [.ja])
    }

    @Test func changeOriginalLanguageBlockedWithCues() {
        var data = SubtitleData(sets: [
            CueSet(name: "a", languages: [.ja]),
            CueSet(name: "b", languages: [.ja], cues: [Cue(start: 0, end: 1, kind: .speech, texts: [.ja: "あ"])]),
        ])
        let before = data
        #expect(throws: SubtitleDataError.originalLanguageLocked) { try data.changeOriginalLanguage(from: .ja, to: .ko) }
        #expect(data == before)
    }

    @Test func changeOriginalLanguageRewritesLanguages() throws {
        var data = SubtitleData(sets: [CueSet(name: "a", languages: [.ja]), CueSet(name: "b", languages: [.ja, .ko]),
                                       CueSet(name: "c", languages: [.en, .ja])])
        try data.changeOriginalLanguage(from: .ja, to: .ko)
        #expect(data.sets.map(\.languages) == [[.ko], [.ko], [.en, .ko]])
        #expect(data.isValid)
    }

    @MainActor @Test func editorChangeIsOneUndoStep() throws {
        let editor = SubtitleDataEditor(data: SubtitleData(sets: [CueSet(name: "a", languages: [.ja])]))
        try editor.changeOriginalLanguage(from: .ja, to: .ko)
        #expect(editor.data.sets[0].languages == [.ko])
        editor.undoManager.undo()
        #expect(editor.data.sets[0].languages == [.ja])
    }

    @Test func displayFallsBackToOriginal() {
        let cue = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "やあ"])
        let set = CueSet(name: "기본", languages: [.ja, .ko], cues: [cue])
        let lines = set.displayCues(at: 500, output: .one(.ko), original: .ja)
        #expect(lines.count == 1)
        #expect(lines[0].language == .ko && lines[0].text == "やあ" && lines[0].isFallback)
        #expect(set.displayText(of: cue, for: .ja, original: .ja) == ("やあ", false))
    }

    @Test func version2ProjectIsLegacy() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let folder = root.appendingPathComponent("옛 영상")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"videoBookmark":"","videoPath":"/v.mp4","videoFileSize":3,"videoDurationMs":10}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        let store = ProjectStore(root: root)
        let summary = try #require(try store.list().first)
        #expect(summary.format == .legacy && summary.isLegacy && !summary.canOpen)
        #expect(throws: ProjectError.legacyFormat(summary.folder)) { try store.load(summary) }
        #expect(ProjectState.currentVersion == 3)
    }
}
