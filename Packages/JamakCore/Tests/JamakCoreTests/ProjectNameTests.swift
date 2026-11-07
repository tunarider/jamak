import Testing
import Foundation
@testable import JamakCore

/// 프로젝트 이름: 처음에는 영상 이름(폴더 이름), project.json에 따로 저장한 이름으로 바꿀 수 있다.
struct ProjectNameTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func video(in dir: URL) throws -> URL {
        let u = dir.appendingPathComponent("港の夏.mp4")
        try Data(count: 10).write(to: u)
        return u
    }

    @Test func renameKeepsFolderAndPersists() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let p = try store.createProject(video: try video(in: base), durationMs: 1000, bookmark: Data(), language: .ja)
        #expect(p.name == "港の夏")

        let renamed = try store.rename(p.summary, to: "  港の夏 (자막 A)  ")
        #expect(renamed.name == "港の夏 (자막 A)")
        #expect(renamed.folder == p.folder)
        let listed = try #require(try store.list().first)
        #expect(listed.name == "港の夏 (자막 A)")
        #expect(listed.folder.lastPathComponent == "港の夏")
        #expect(try store.load(listed).name == "港の夏 (자막 A)")
    }

    @Test func emptyNameFallsBackToFolderName() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let p = try store.createProject(video: try video(in: base), durationMs: 1000, bookmark: Data(), language: .ja)
        _ = try store.rename(p.summary, to: "다른 이름")
        let reset = try store.rename(try #require(try store.list().first), to: "   ")
        #expect(reset.name == "港の夏")
        #expect(try store.list().first?.state?.name == nil)
    }

    @Test func savingOpenProjectKeepsItsName() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 1000, bookmark: Data(), language: .ja)
        p.state.name = "새 이름"
        try store.saveState(p)
        #expect(try store.list().first?.name == "새 이름")
    }

    @Test func findProjectPrefersMostRecentlyOpened() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let v = try video(in: base)
        var a = try store.createProject(video: v, durationMs: 1000, bookmark: Data(), language: .ja)
        var b = try store.createProject(video: v, durationMs: 1000, bookmark: Data(), language: .ja)
        #expect(b.folder.lastPathComponent == "港の夏 2")
        a.state.lastOpenedAt = Date(timeIntervalSince1970: 100)
        b.state.lastOpenedAt = Date(timeIntervalSince1970: 200)
        try store.saveState(a)
        try store.saveState(b)
        // 임시 폴더는 /var와 /private/var로 달리 보일 수 있어 폴더 이름으로 비교한다.
        #expect(try store.findProject(forVideo: v)?.folder.lastPathComponent == "港の夏 2")
        #expect(try store.projects(forVideo: v).map(\.folder.lastPathComponent) == ["港の夏 2", "港の夏"])
    }
}
