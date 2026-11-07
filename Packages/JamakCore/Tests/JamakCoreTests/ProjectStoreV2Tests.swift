import Testing
import Foundation
@testable import JamakCore

struct ProjectStoreV2Tests {
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
    func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    @Test func createMakesInitialSetAndFiles() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let p = try store.createProject(video: try video(in: base), durationMs: 120000, bookmark: Data(),
                                        language: .ja)
        #expect(p.subtitles.sets.count == 1)
        let set = p.subtitles.sets[0]
        #expect(set.name == "기본" && set.languages == [.ja] && set.cues.isEmpty)
        #expect(p.state.version == 3 && p.state.originalLanguage == .ja)
        #expect(FileManager.default.fileExists(atPath: p.folder.appendingPathComponent("subtitles.json").path))
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: p.folder.appendingPathComponent("project.json"))) as? [String: Any]
        #expect(json?["version"] as? Int == 3)
        let loaded = try store.load(try #require(try store.list().first))
        #expect(loaded.subtitles == p.subtitles)
    }

    @Test func saveLoadRoundTrip() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 120000, bookmark: Data(),
                                        language: .ja)
        let setID = p.subtitles.sets[0].id
        try p.subtitles.sets[0].addLanguage(.ko)
        let cue = Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "あ", .ko: "아"])
        p.subtitles.sets[0].cues = [cue, Cue(start: 1500, end: 2500, kind: .sound, texts: [.ja: "音"])]
        let second = p.subtitles.addSet(name: "두 번째", like: p.subtitles.sets[0])
        p.state.lastOpenedSetID = second
        p.state.outputLanguages = [setID: .all, second: .one(.ko)]
        p.state.tickets = TicketBook(tickets: [
            Ticket(setID: setID, origin: .translation, language: .ko, level: .suspect, reason: "이상함",
                   changes: [TicketChange(cueID: cue.id, before: "아", after: "어")])])
        var g = GenerationProgress(); g.transcribed = true
        p.state.setGeneration = [setID: g]
        var t = TranslationProgress(sourceLanguage: "ja"); t.translated = true
        p.state.setTranslations = [ProjectState.translationKey(set: setID, language: .ko): t]
        try store.save(p)

        let listed = try store.list()
        #expect(listed.count == 1)
        let loaded = try store.load(listed[0])
        #expect(same(loaded.folder, p.folder))
        #expect(loaded.subtitles == p.subtitles)
        #expect(loaded.state == p.state)
        #expect(loaded.state.setTranslations?.keys.first == "\(setID.uuidString)/ko")

        // subtitles.json은 키 정렬로 쓴다.
        let text = try String(contentsOf: p.folder.appendingPathComponent("subtitles.json"), encoding: .utf8)
        let sortedOnce = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: Data(text.utf8)), options: [.sortedKeys])
        #expect(try JSONDecoder().decode(SubtitleData.self, from: sortedOnce) == p.subtitles)
        #expect(text.range(of: "\"cues\"")!.lowerBound < text.range(of: "\"languages\"")!.lowerBound)
    }

    @Test func atomicSaveLeavesOldFileOnFailure() throws {
        let base = try tmp()
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 60000, bookmark: Data(),
                                        language: .ja)
        p.subtitles.sets[0].cues = [Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "前"])]
        try store.save(p)
        let subsURL = p.folder.appendingPathComponent("subtitles.json")
        let stateURL = p.folder.appendingPathComponent("project.json")
        let subsBefore = try Data(contentsOf: subsURL)
        let stateBefore = try Data(contentsOf: stateURL)

        // 폴더를 읽기 전용으로 만들어 임시 파일을 만들 수 없게 한다(파일 자체는 쓰기 가능).
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: p.folder.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.folder.path)
            try? fm.removeItem(at: base)
        }
        var next = p
        next.subtitles.sets[0].cues = [Cue(start: 0, end: 1000, kind: .speech, texts: [.ja: "後"])]
        var g = GenerationProgress(); g.transcribed = true
        next.state.setGeneration = [p.subtitles.sets[0].id: g]
        #expect(throws: (any Error).self) { try store.save(next) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.folder.path)
        #expect(try Data(contentsOf: subsURL) == subsBefore)
        #expect(try Data(contentsOf: stateURL) == stateBefore)
        #expect(try store.load(try #require(try store.list().first)).subtitles == p.subtitles)
    }

    /// 테스트용 휴지통: 진짜 ~/.Trash 대신 `bin` 폴더로 옮긴다.
    func fakeTrash(_ bin: URL) -> ProjectStore.Trash {
        { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let dest = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    func writeState(_ json: String, in root: URL, folder name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func stateJSON(version: String?, path: String, size: Int = 10, extra: String = "") -> String {
        let v = version.map { "\"version\":\($0)," } ?? ""
        return """
        {\(v)"originalLanguage":"ja","videoBookmark":"","videoPath":"\(path)","videoFileSize":\(size),"videoDurationMs":1\(extra)}
        """
    }

    @Test func legacyFolderListedAsLegacy() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let store = ProjectStore(root: root)
        let v = try video(in: base)
        _ = try store.createProject(video: v, durationMs: 1, bookmark: Data(), language: .ko)

        let old = try writeState(stateJSON(version: "1", path: v.path, extra: #","annotations":[]"#),
                                 in: root, folder: "예전 영상")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nあ\n".utf8).write(to: old.appendingPathComponent("ja.srt"))
        _ = try writeState(stateJSON(version: nil, path: v.path), in: root, folder: "버전 없음")
        let notProject = root.appendingPathComponent("빈 폴더", isDirectory: true)
        try FileManager.default.createDirectory(at: notProject, withIntermediateDirectories: true)

        let listed = try store.list()
        #expect(listed.count == 3)
        let legacy = listed.filter(\.isLegacy)
        #expect(Set(legacy.map(\.name)) == ["예전 영상", "버전 없음"])
        #expect(legacy.allSatisfy { $0.format == .legacy && $0.state == nil && $0.languages.isEmpty && $0.setCount == 0 })
        #expect(listed.filter { $0.format == .current }.count == 1)

        // 같은 영상의 예전 폴더는 찾지 않는다(새 프로젝트를 만들 수 있다).
        let found = try #require(try store.findProject(forVideo: v))
        #expect(found.format == .current && found.name == "港の夏")
        // 예전 형식은 열 수 없다.
        let oldSummary = try #require(legacy.first { $0.name == "예전 영상" })
        #expect(throws: ProjectError.legacyFormat(oldSummary.folder)) { try store.load(oldSummary) }
    }

    @Test func newerVersionListedAsNewerAndNotOpened() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let store = ProjectStore(root: root)
        let v = try video(in: base)
        let folder = try writeState(stateJSON(version: "4", path: v.path, extra: #","somethingNew":{"a":1}"#),
                                    in: root, folder: "새 버전")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("subtitles.json"))

        let s = try #require(try store.list().first)
        #expect(s.format == .newer && !s.isLegacy && s.state == nil && !s.canOpen)
        #expect(throws: ProjectError.newerFormat(s.folder)) { try store.load(s) }
        // 같은 영상을 다시 열면 이 폴더를 찾는다(옆에 "<이름> 2"를 만들지 않는다).
        let found = try #require(try store.findProject(forVideo: v))
        #expect(found.format == .newer && same(found.folder, folder))
    }

    @Test func undecodableV2ListedAsCorruptNotLegacy() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let store = ProjectStore(root: root)
        let v = try video(in: base)
        let p = try store.createProject(video: v, durationMs: 1, bookmark: Data(), language: .ja)
        // 필수 필드가 깨진 버전 2(영상 경로·크기는 읽힌다).
        let state = p.folder.appendingPathComponent("project.json")
        try Data(#"{"version":3,"originalLanguage":"ja","videoBookmark":"","videoPath":"\#(v.path)","videoFileSize":10,"videoDurationMs":"x"}"#.utf8)
            .write(to: state)
        _ = try writeState("not json", in: root, folder: "잘린 것")

        let listed = try store.list()
        #expect(listed.count == 2)
        #expect(listed.allSatisfy { $0.format == .corrupt && !$0.isLegacy && $0.state == nil && !$0.canOpen })
        let s = try #require(listed.first { same($0.folder, p.folder) })
        #expect(throws: ProjectError.corruptState(s.folder)) { try store.load(s) }
        // 같은 영상을 다시 열면 깨진 프로젝트를 찾는다(옆에 중복 프로젝트를 만들지 않는다).
        let found = try #require(try store.findProject(forVideo: v))
        #expect(found.format == .corrupt && same(found.folder, p.folder))
    }

    @Test func badOptionalEntriesAreDroppedNotHidingProject() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 1, bookmark: Data(), language: .ja)
        let setID = p.subtitles.sets[0].id
        let cue = Cue(start: 0, end: 1, kind: .speech, texts: [.ja: "あ"])
        p.subtitles.sets[0].cues = [cue]
        try store.save(p)
        let change = #"[{"cueID":"\#(cue.id.uuidString)","before":"あ","after":"い"}]"#
        func ticket(level: String = "fix", language: String = "ja", origin: String = "source",
                    changes: String) -> String {
            let head = #"{"id":"\#(UUID().uuidString)","setID":"\#(setID.uuidString)","origin":"\#(origin)""#
            return head + #","language":"\#(language)","level":"\#(level)","reason":"r","changes":\#(changes)}"#
        }
        let good = ticket(changes: change)
        let badTickets = [
            ticket(language: "xx", changes: change),
            ticket(level: "weird", changes: change),
            ticket(origin: "weird", changes: change),
            ticket(changes: "[]"),
            #"{"level":"suspect"}"#,
        ]
        let other = UUID().uuidString
        let json = """
        {"version":3,"originalLanguage":"ja","videoBookmark":"","videoPath":"/v.mp4","videoFileSize":3,"videoDurationMs":10,
         "tickets":{"tickets":[\(good),\(badTickets.joined(separator: ","))]},
         "setGeneration":{"\(setID.uuidString)":{"transcribed":true},"\(other)":{"transcribed":"yes"}},
         "setTranslations":{"\(setID.uuidString)/ko":{"sourceLanguage":"ja","translated":true},"\(other)/en":{"redoAll":1}},
         "outputLanguages":{"\(setID.uuidString)":"all","\(other)":5},
         "tokenUsage":{"tasks":{"analyze":{"input":"lots"}}}}
        """
        try Data(json.utf8).write(to: p.folder.appendingPathComponent("project.json"))

        let s = try #require(try store.list().first)
        #expect(s.format == .current && s.canOpen)
        let state = try #require(s.state)
        #expect(state.tickets?.tickets.count == 1 && state.tickets?.tickets.first?.reason == "r")
        #expect(s.openTicketCount == 1)
        #expect(state.setGeneration?.count == 1 && state[generation: setID]?.transcribed == true)
        #expect(state.setTranslations?.count == 1 && state[translation: setID, .ko]?.translated == true)
        #expect(state.outputLanguages == [setID: .all])
        #expect(state.tokenUsage == nil || state.tokenUsage?.tasks.isEmpty == true)
        #expect(try store.load(s).subtitles == p.subtitles)

        // 블록 자체가 엉뚱한 모양이어도 블록만 버린다.
        let shapeless = """
        {"version":3,"originalLanguage":"ja","videoBookmark":"","videoPath":"/v.mp4","videoFileSize":3,"videoDurationMs":10,
         "tickets":[1,2],"setGeneration":"x","setTranslations":[],"outputLanguages":true,"tokenUsage":7}
        """
        let st = try JSONDecoder().decode(ProjectState.self, from: Data(shapeless.utf8))
        #expect(st.tickets == nil && st.setGeneration == nil && st.setTranslations == nil)
        #expect(st.outputLanguages == nil && st.tokenUsage == nil)
    }

    @Test func createProjectRemovesPartialFolderOnFailure() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let store = ProjectStore(root: root)
        let missing = base.appendingPathComponent("없는 영상.mp4")
        #expect(throws: (any Error).self) {
            try store.createProject(video: missing, durationMs: 1, bookmark: Data(), language: .ja)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func saveRefusesInvalidSubtitles() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 1, bookmark: Data(), language: .ja)
        let subs = p.folder.appendingPathComponent("subtitles.json")
        let state = p.folder.appendingPathComponent("project.json")
        let (subsBefore, stateBefore) = (try Data(contentsOf: subs), try Data(contentsOf: state))
        p.subtitles.sets = []
        p.state.lastOpenedSetID = UUID()
        #expect(throws: ProjectError.invalidSubtitles(p.folder)) { try store.save(p) }
        #expect(try Data(contentsOf: subs) == subsBefore)
        #expect(try Data(contentsOf: state) == stateBefore)
    }

    @Test func listSummaryCountsSetsAndLanguages() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 1, bookmark: Data(), language: .ja)
        p.subtitles.sets[0].cues = [Cue(start: 0, end: 1, kind: .speech), Cue(start: 1, end: 2, kind: .speech)]
        var other = CueSet(name: "다른", languages: [.en, .ko])
        other.cues = [Cue(start: 0, end: 1, kind: .sound)]
        p.subtitles.sets.append(other)
        try store.save(p)

        let s = try #require(try store.list().first)
        #expect(!s.isLegacy)
        #expect(s.setCount == 2)
        #expect(s.cueCount == 3)
        #expect(s.languages == [.ko, .ja, .en])
        #expect(p.summary.languages == [.ko, .ja, .en])
        #expect(p.summary.setCount == 2 && p.summary.cueCount == 3)
    }

    @Test func deleteLegacyToTrash() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let bin = base.appendingPathComponent("Trash")
        let store = ProjectStore(root: root, trash: fakeTrash(bin))
        let old = root.appendingPathComponent("예전 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"version":1}"#.utf8).write(to: old.appendingPathComponent("project.json"))
        let summary = try #require(try store.list().first)
        #expect(summary.isLegacy)
        let trashed = try #require(try store.delete(summary, toTrash: true))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(trashed.deletingLastPathComponent().lastPathComponent == "Trash")
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("project.json").path))
        #expect(try store.list().isEmpty)
    }

    @Test func missingOrInvalidSubtitlesIsCorrupt() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        let p = try store.createProject(video: try video(in: base), durationMs: 1, bookmark: Data(), language: .ja)
        let subs = p.folder.appendingPathComponent("subtitles.json")
        let set = p.subtitles.sets[0]
        let dupID = UUID()
        let bad: [SubtitleData] = [
            SubtitleData(sets: []),
            SubtitleData(sets: [CueSet(name: "a", languages: [])]),
            SubtitleData(sets: [CueSet(name: "a", languages: [.ja, .ja])]),
            SubtitleData(sets: [CueSet(id: set.id, name: "a", languages: [.ja],
                                       cues: [Cue(id: dupID, start: 0, end: 1, kind: .speech),
                                              Cue(id: dupID, start: 1, end: 2, kind: .speech)])]),
        ]
        for data in bad {
            #expect(!data.isValid)
            try JSONEncoder().encode(data).write(to: subs)
            let s = try #require(try store.list().first)
            #expect(!s.isLegacy)
            #expect(throws: ProjectError.corruptProject(s.folder)) { try store.load(s) }
        }
        try Data("{".utf8).write(to: subs)
        let s1 = try #require(try store.list().first)
        #expect(throws: ProjectError.corruptProject(s1.folder)) { try store.load(s1) }
        try FileManager.default.removeItem(at: subs)
        let s2 = try #require(try store.list().first)
        #expect(throws: ProjectError.corruptProject(s2.folder)) { try store.load(s2) }
        #expect(p.subtitles.isValid)
    }

    @Test func saveStateWritesOnlyProjectJson() throws {
        let base = try tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(root: base.appendingPathComponent("Projects"))
        var p = try store.createProject(video: try video(in: base), durationMs: 1, bookmark: Data(), language: .ja)
        let subsBefore = try Data(contentsOf: p.folder.appendingPathComponent("subtitles.json"))
        p.subtitles.sets[0].cues = [Cue(start: 0, end: 1, kind: .speech, texts: [.ja: "未保存"])]
        p.state.lastOpenedSetID = p.subtitles.sets[0].id
        try store.saveState(p)
        #expect(try Data(contentsOf: p.folder.appendingPathComponent("subtitles.json")) == subsBefore)
        let loaded = try store.load(try #require(try store.list().first))
        #expect(loaded.state.lastOpenedSetID == p.subtitles.sets[0].id)
        #expect(loaded.subtitles.sets[0].cues.isEmpty)
    }

    @Test func stateDecodesWithoutOptionalFieldsAndSkipsBadKeys() throws {
        let id = UUID()
        let json = """
        {"version":3,"originalLanguage":"ja","videoBookmark":"","videoPath":"/v.mp4","videoFileSize":3,"videoDurationMs":10,
         "outputLanguages":{"\(id.uuidString)":"ja","not-a-uuid":"ko","\(UUID().uuidString)":"xx"}}
        """
        let state = try JSONDecoder().decode(ProjectState.self, from: Data(json.utf8))
        #expect(state.version == 3)
        #expect(state.lastOpenedAt == nil && state.lastOpenedSetID == nil && state.tickets == nil)
        #expect(state.setGeneration == nil && state.setTranslations == nil && state.tokenUsage == nil)
        #expect(state.outputLanguages == [id: .one(.ja)])
    }
}

/// 지운 자막셋과 없는 조각·언어의 상태는 저장할 때 버리고, 목록 요약은 지금 있는 자막셋만 센다.
struct ProjectStatePruneTests {
    let kept = UUID(), gone = UUID()

    func data(cue: Cue) -> SubtitleData {
        SubtitleData(sets: [CueSet(id: kept, name: "기본", languages: [.ja, .ko], cues: [cue])])
    }

    func ticket(_ set: UUID, _ cues: [UUID], _ language: Language, _ reason: String) -> Ticket {
        Ticket(setID: set, origin: .source, language: language, level: .suspect, reason: reason,
               changes: cues.map { TicketChange(cueID: $0, before: "あ", after: "い") })
    }

    func staleState(cue: UUID) -> ProjectState {
        var g = GenerationProgress(); g.transcribed = true
        var t = TranslationProgress(sourceLanguage: "ja"); t.translated = true
        return ProjectState(
            originalLanguage: .ja, videoBookmark: Data(), videoPath: "/v.mp4", videoFileSize: 1, videoDurationMs: 10_000,
            outputLanguages: [kept: .all, gone: .one(.ko)],
            tickets: TicketBook(tickets: [
                ticket(kept, [cue, UUID()], .ja, "남음"),
                ticket(kept, [cue], .en, "없는 언어"),
                ticket(kept, [UUID()], .ja, "없는 조각"),
                ticket(gone, [cue], .ja, "없는 자막셋"),
            ]),
            setGeneration: [kept: g, gone: g],
            setTranslations: [ProjectState.translationKey(set: kept, language: .ko): t,
                              ProjectState.translationKey(set: gone, language: .ko): t, "엉뚱한 키": t])
    }

    @Test func pruneDropsDeletedSetEntriesAndOrphanTickets() {
        let cue = Cue(start: 0, end: 1, kind: .speech, texts: [.ja: "あ"])
        var state = staleState(cue: cue.id)
        state.prune(to: data(cue: cue))
        #expect(state.outputLanguages == [kept: .all])
        #expect(Array(state.setGeneration?.keys ?? [:].keys) == [kept])
        #expect(Array(state.setTranslations?.keys ?? [:].keys) == [ProjectState.translationKey(set: kept, language: .ko)])
        #expect(state.tickets?.tickets.map(\.reason) == ["남음"])
        #expect(state.tickets?.tickets.first?.cueIDs == [cue.id])
        // 다시 해도 같다.
        var again = state
        again.prune(to: data(cue: cue))
        #expect(again == state)
    }

    @Test func summaryCountsOnlyExistingSets() {
        let cue = Cue(start: 0, end: 1, kind: .speech, texts: [.ja: "あ"])
        var state = staleState(cue: cue.id)
        var paused = GenerationProgress(); paused.audioExtracted = true
        state.setGeneration = [gone: paused]
        var part = TranslationProgress(sourceLanguage: "ja"); part.glossaryDone = true
        state.setTranslations = [ProjectState.translationKey(set: gone, language: .ko): part]
        let s = ProjectSummary(folder: URL(fileURLWithPath: "/p"), state: state, subtitles: data(cue: cue))
        #expect(s.state?.setGeneration?.isEmpty != false)
        #expect(!ProjectFilter.resumable.includes(s))
        #expect(WorkflowStatus(state: s.state!, hasSourceSet: true).stoppedStepName == nil)
        #expect(s.openTicketCount == 1)
    }

    @Test func removeOrphanWorkKeepsLiveSetsAndOtherFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Projects")
        let store = ProjectStore(root: root)
        let video = base.appendingPathComponent("v.mp4")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(count: 3).write(to: video)
        let p = try store.createProject(video: video, durationMs: 1, bookmark: Data(), language: .ja)
        let work = p.folder.appendingPathComponent("work", isDirectory: true)
        let live = work.appendingPathComponent(p.subtitles.sets[0].id.uuidString, isDirectory: true)
        let dead = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let other = work.appendingPathComponent("notes", isDirectory: true)
        for d in [live, dead, other] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent("correct-ja"), withIntermediateDirectories: true)
        }
        store.removeOrphanWork(p)
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
