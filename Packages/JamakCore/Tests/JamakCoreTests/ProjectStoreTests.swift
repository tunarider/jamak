import Testing
import Foundation
@testable import JamakCore

struct ProjectStoreTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func video(in dir: URL, name: String = "港の夏.mp4", bytes: Int = 10) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: u)
        return u
    }

    @Test func listSortsByLastOpenedThenModification() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var a = try store.createProject(video: try video(in: base.appendingPathComponent("a"), name: "a.mp4"),
                                        durationMs: 1, bookmark: Data(), language: .ja)
        let b = try store.createProject(video: try video(in: base.appendingPathComponent("b"), name: "b.mp4"),
                                        durationMs: 1, bookmark: Data(), language: .ja)
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: a.folder.appendingPathComponent("project.json").path)
        #expect(try store.list().map(\.name) == ["b", "a"])
        a.state.lastOpenedAt = Date(timeIntervalSinceNow: 60)
        try store.saveState(a)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: a.folder.appendingPathComponent("project.json").path)
        #expect(try store.list().map(\.name) == ["a", "b"])
        _ = b
    }

    @Test func decodesStateWithoutLastOpenedAt() throws {
        let json = #"{"version":3,"originalLanguage":"ja","videoBookmark":"","videoPath":"/v.mp4","videoFileSize":3,"videoDurationMs":10,"annotations":[]}"#
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.lastOpenedAt == nil)
        #expect(state.videoDurationMs == 10)
    }

    @Test func nameCollisionAddsSuffix() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let a = try store.createProject(video: try video(in: base.appendingPathComponent("a")), durationMs: 1, bookmark: Data(), language: .ja)
        let b = try store.createProject(video: try video(in: base.appendingPathComponent("b")), durationMs: 1, bookmark: Data(), language: .ja)
        #expect(a.folder.lastPathComponent == "港の夏")
        #expect(b.folder.lastPathComponent == "港の夏 2")
    }

    @Test func findsExistingProjectForSameVideo() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        _ = try store.createProject(video: v, durationMs: 1, bookmark: Data(), language: .ja)
        #expect(try store.findProject(forVideo: v) != nil)
        try Data(count: 99).write(to: v)
        #expect(try store.findProject(forVideo: v) == nil)
    }

    @Test func resolveReportsMissingVideo() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        let p = try store.createProject(video: v, durationMs: 1, bookmark: Data(), language: .ja)
        #expect(store.resolveVideo(p) == .ok(v))
        try FileManager.default.removeItem(at: v)
        #expect(store.resolveVideo(p) == .missing)
    }

    @Test func resolveReportsStaleBookmark() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        let p = try store.createProject(video: v, durationMs: 1, bookmark: try v.bookmarkData(), language: .ja)
        guard case .ok(let fresh, let freshStale) = store.resolveVideo(p) else {
            Issue.record("video should resolve"); return
        }
        #expect(fresh.resolvingSymlinksInPath().path == v.resolvingSymlinksInPath().path)
        #expect(!freshStale)
        let moved = base.appendingPathComponent("moved.mp4")
        try FileManager.default.moveItem(at: v, to: moved)
        guard case .ok(let url, let isStale) = store.resolveVideo(p) else {
            Issue.record("moved video should still resolve"); return
        }
        #expect(url.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
        #expect(isStale)
    }

    @Test func relinkRejectsDifferentDuration() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        var p = try store.createProject(video: v, durationMs: 120000, bookmark: Data(), language: .ja)
        let v2 = try video(in: base.appendingPathComponent("new"), bytes: 20)
        #expect(throws: ProjectError.durationMismatch(expected: 120000, actual: 122500)) {
            try store.relink(&p, to: v2, durationMs: 122500, bookmark: Data())
        }
        try store.relink(&p, to: v2, durationMs: 120800, bookmark: Data())
        #expect(p.state.videoPath == v2.path)
        #expect(p.state.videoFileSize == 20)
        #expect(try store.list().first?.state?.videoPath == v2.path)
    }

    @Test func deleteKeepsOriginalVideo() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        let p = try store.createProject(video: v, durationMs: 1, bookmark: Data(), language: .ja)
        try store.delete(p)
        #expect(!FileManager.default.fileExists(atPath: p.folder.path))
        #expect(FileManager.default.fileExists(atPath: v.path))
    }

    @Test func deleteRefusesFolderOutsideRoot() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        // 휴지통으로 옮기려 하면 테스트가 실패한다(진짜 ~/.Trash를 건드리지 않는다).
        let store = ProjectStore(root: base.appendingPathComponent("Projects"), trash: { url in
            Issue.record("trashed \(url.path)")
            return nil
        })
        let outside = base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let nested = base.appendingPathComponent("Projects/a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let state = ProjectState(originalLanguage: .ja, videoBookmark: Data(), videoPath: "", videoFileSize: 0, videoDurationMs: 1)
        for folder in [outside, nested, base.appendingPathComponent("Projects")] {
            #expect(throws: ProjectError.outsideRoot(folder)) {
                try store.delete(Project(folder: folder, state: state,
                                         subtitles: SubtitleData(sets: [.initial(language: .ja)])), toTrash: true)
            }
            #expect(throws: ProjectError.outsideRoot(folder)) {
                try store.delete(ProjectSummary.legacy(folder: folder), toTrash: true)
            }
            #expect(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test func failedSubtitleWriteLeavesProjectStateUnchanged() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 60000, bookmark: Data(), language: .ja)
        p.subtitles.sets[0].cues = [Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "前"])]
        try store.save(p)
        let stateURL = p.folder.appendingPathComponent("project.json")
        let before = try Data(contentsOf: stateURL)

        // subtitles.json 자리를 폴더로 막아 원자적 쓰기가 실패하게 한다.
        let subs = p.folder.appendingPathComponent("subtitles.json")
        try FileManager.default.removeItem(at: subs)
        try FileManager.default.createDirectory(at: subs.appendingPathComponent("blocker"), withIntermediateDirectories: true)

        var next = p
        var g = GenerationProgress(); g.transcribed = true
        next.state.setGeneration = [p.subtitles.sets[0].id: g]
        next.subtitles.sets[0].cues = [Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "後"])]
        #expect(throws: (any Error).self) { try store.save(next) }
        #expect(try Data(contentsOf: stateURL) == before)
    }
}
