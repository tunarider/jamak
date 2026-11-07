import Foundation

public final class ProjectStore: @unchecked Sendable {
    private let root: URL
    private let fm = FileManager.default
    private static let stateFile = "project.json"
    private static let subtitlesFile = "subtitles.json"

    /// 폴더를 휴지통으로 옮기고 휴지통 안의 위치를 돌려준다. 테스트는 진짜 휴지통 대신 다른 것을 넣는다.
    public typealias Trash = @Sendable (URL) throws -> URL?
    private let trash: Trash

    public init(root: URL, trash: Trash? = nil) {
        self.root = root
        self.trash = trash ?? { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return trashed as URL?
        }
    }

    private func stateURL(_ folder: URL) -> URL { folder.appendingPathComponent(Self.stateFile) }
    private func subtitlesURL(_ folder: URL) -> URL { folder.appendingPathComponent(Self.subtitlesFile) }

    /// Most recently opened first (`state.lastOpenedAt`, falling back to the
    /// project.json modification date). Folders without project.json are skipped.
    /// project.json의 `version`을 먼저 읽는다: 없거나 3보다 작으면 예전 형식(`.legacy`), 3보다 크면 새 형식
    /// (`.newer`), 3인데 전체를 읽지 못하면(또는 JSON이 아니면) 깨진 것(`.corrupt`)이다. 셋 다 `state`가 없다.
    /// A format-3 project whose subtitles.json is missing or broken is still listed (with zero counts); `load` then throws.
    public func list() throws -> [ProjectSummary] {
        try entries().map(\.summary)
    }

    private struct Entry {
        let summary: ProjectSummary
        /// project.json에서 읽은 영상 경로와 크기. 열 수 없는 폴더도 읽히면 채운다(같은 영상 찾기).
        let videoPath: String?
        let videoFileSize: Int64?
    }

    private func entries() throws -> [Entry] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var found: [(Entry, Date)] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let e = entry(folder: folder) else { continue }
            let recency = e.summary.state?.lastOpenedAt
                ?? (try? stateURL(folder).resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                ?? .distantPast
            found.append((e, recency))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// project.json에서 형식 판별과 같은 영상 찾기에 쓰는 부분만 읽는다. `version`이 숫자가 아니면 실패한다.
    private struct StateHeader: Decodable {
        var version: Int?
        var videoPath: String?
        var videoFileSize: Int64?

        private enum CodingKeys: String, CodingKey { case version, videoPath, videoFileSize }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            videoPath = try? c.decodeIfPresent(String.self, forKey: .videoPath)
            videoFileSize = try? c.decodeIfPresent(Int64.self, forKey: .videoFileSize)
        }
    }

    /// nil이면 프로젝트 폴더가 아니다(project.json이 없다).
    private func entry(folder: URL) -> Entry? {
        guard let data = try? Data(contentsOf: stateURL(folder)) else { return nil }
        guard let header = try? JSONDecoder().decode(StateHeader.self, from: data) else {
            // JSON이 아니거나 version이 숫자가 아니다. 예전 형식은 늘 읽히는 JSON이었으니 깨진 것으로 본다.
            return Entry(summary: .unopenable(folder: folder, format: .corrupt), videoPath: nil, videoFileSize: nil)
        }
        func unopenable(_ format: ProjectSummary.Format) -> Entry {
            Entry(summary: .unopenable(folder: folder, format: format),
                  videoPath: header.videoPath, videoFileSize: header.videoFileSize)
        }
        let version = header.version ?? 1
        if version < ProjectState.currentVersion { return unopenable(.legacy) }
        if version > ProjectState.currentVersion { return unopenable(.newer) }
        guard let state = try? JSONDecoder().decode(ProjectState.self, from: data) else { return unopenable(.corrupt) }
        let summary = (try? readSubtitles(folder)).map { ProjectSummary(folder: folder, state: state, subtitles: $0) }
            ?? ProjectSummary(folder: folder, state: state)
        return Entry(summary: summary, videoPath: state.videoPath, videoFileSize: state.videoFileSize)
    }

    private func readSubtitles(_ folder: URL) throws -> SubtitleData {
        guard let data = try? Data(contentsOf: subtitlesURL(folder)),
              let subtitles = try? JSONDecoder().decode(SubtitleData.self, from: data),
              subtitles.isValid else {
            throw ProjectError.corruptProject(folder)
        }
        return subtitles
    }

    /// Reads subtitles.json. 열 수 없는 요약이면 형식에 따라 `legacyFormat`, `newerFormat`, `corruptState`를
    /// 던진다. subtitles.json이 없거나 읽히지 않거나 불변식(`SubtitleData.isValid`)을 어기면 `corruptProject`.
    public func load(_ summary: ProjectSummary) throws -> Project {
        switch summary.format {
        case .current: break
        case .legacy: throw ProjectError.legacyFormat(summary.folder)
        case .newer: throw ProjectError.newerFormat(summary.folder)
        case .corrupt: throw ProjectError.corruptState(summary.folder)
        }
        guard let state = summary.state else { throw ProjectError.corruptState(summary.folder) }
        return Project(folder: summary.folder, state: state,
                       subtitles: try readSubtitles(summary.folder))
    }

    /// Same video = same current path and same current file size. Legacy folders are skipped (예전 형식 옆에는
    /// 새 프로젝트를 만든다). 깨진 폴더와 새 형식 폴더도 영상 경로·크기가 읽히면 찾는다. 그러면 호출자가
    /// 열려다 그 까닭을 알리고, 같은 영상의 중복 프로젝트("<이름> 2")를 옆에 만들지 않는다.
    /// 같은 영상(경로와 크기)의 프로젝트 중 가장 최근에 연 것.
    public func findProject(forVideo url: URL) throws -> ProjectSummary? {
        try projects(forVideo: url).first
    }

    /// 같은 영상의 프로젝트들, 최근에 연 순서.
    public func projects(forVideo url: URL) throws -> [ProjectSummary] {
        let size = try fileSize(url)
        return try entries().filter {
            !$0.summary.isLegacy && $0.videoPath == url.path && $0.videoFileSize == size
        }.map(\.summary)
    }

    /// 프로젝트 이름을 바꾼다(폴더는 그대로, project.json의 `name`만). 앞뒤 빈칸은 빼고, 비면 폴더 이름으로 돌아간다.
    /// 열려 있는 프로젝트는 앱이 들고 있는 상태로 다시 저장하니, 앱은 자기 상태에도 같은 이름을 넣어야 한다.
    @discardableResult
    public func rename(_ summary: ProjectSummary, to name: String) throws -> ProjectSummary {
        guard summary.canOpen else { throw ProjectError.corruptState(summary.folder) }
        var state = try JSONDecoder().decode(ProjectState.self, from: Data(contentsOf: stateURL(summary.folder)))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.name = trimmed.isEmpty ? nil : trimmed
        try Self.encoder.encode(state).write(to: stateURL(summary.folder), options: .atomic)
        var renamed = summary
        renamed.state?.name = state.name
        renamed.name = state.name ?? summary.folder.lastPathComponent
        return renamed
    }

    /// 폴더와 subtitles.json("기본" 자막셋 하나, 언어는 `language`), project.json을 만든다.
    public func createProject(video: URL, durationMs: Int, bookmark: Data, language: Language) throws -> Project {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = video.deletingPathExtension().lastPathComponent
        var folder = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let state = ProjectState(originalLanguage: language, videoBookmark: bookmark, videoPath: video.path,
                                     videoFileSize: try fileSize(video), videoDurationMs: durationMs)
            let p = Project(folder: folder, state: state, subtitles: SubtitleData(sets: [.initial(language: language)]))
            try save(p)
            return p
        } catch {
            // 반쯤 만든 폴더를 남기지 않는다.
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Writes subtitles.json first and project.json last, each atomically (temp
    /// file in the same folder, then rename), so a progress flag is never
    /// persisted ahead of the subtitles it describes and a failed write leaves
    /// the previous file intact. 자막 데이터가 불변식(`SubtitleData.isValid`)을 어기면 아무것도 쓰지 않고
    /// `invalidSubtitles`를 던진다(쓰고 나면 `load`가 깨진 프로젝트로 보고 열지 못한다).
    public func save(_ p: Project) throws {
        guard p.subtitles.isValid else { throw ProjectError.invalidSubtitles(p.folder) }
        try fm.createDirectory(at: p.folder, withIntermediateDirectories: true)
        try Self.encoder.encode(p.subtitles).write(to: subtitlesURL(p.folder), options: .atomic)
        try saveState(p)
    }

    /// 지운 자막셋의 LLM 중간 저장(`work/<자막셋 id>/`)을 지운다. 자막셋 id가 아닌 이름은 건드리지 않는다.
    /// 실패해도 던지지 않는다(다음 저장에서 다시 해 본다). 폴더를 지우니 메인 밖에서 부른다.
    public func removeOrphanWork(_ p: Project) {
        let work = p.folder.appendingPathComponent("work", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: work.path) else { return }
        let live = Set(p.subtitles.sets.map(\.id))
        for name in entries {
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            try? fm.removeItem(at: work.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// project.json만 쓴다(원자적). 자막의 저장 안 된 변경은 건드리지 않는다.
    public func saveState(_ p: Project) throws {
        try fm.createDirectory(at: p.folder, withIntermediateDirectories: true)
        try Self.encoder.encode(p.state).write(to: stateURL(p.folder), options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    /// The caller (app) must call `startAccessingSecurityScopedResource()` on the
    /// returned URL before reading the video. When `isStale` is true (or the path
    /// changed), the caller should store a fresh bookmark.
    public func resolveVideo(_ p: Project) -> VideoResolution {
        let bookmark = p.state.videoBookmark
        if !bookmark.isEmpty {
            var stale = false
            let url = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [],
                             relativeTo: nil, bookmarkDataIsStale: &stale))
            if let url, fm.fileExists(atPath: url.path) { return .ok(url, isStale: stale) }
            return .missing
        }
        let url = URL(fileURLWithPath: p.state.videoPath)
        return fm.fileExists(atPath: url.path) ? .ok(url) : .missing
    }

    public func relink(_ p: inout Project, to url: URL, durationMs: Int, bookmark: Data) throws {
        let expected = p.state.videoDurationMs
        guard abs(durationMs - expected) <= 1000 else {
            throw ProjectError.durationMismatch(expected: expected, actual: durationMs)
        }
        p.state.videoBookmark = bookmark
        p.state.videoPath = url.path
        p.state.videoFileSize = try fileSize(url)
        p.state.videoDurationMs = durationMs
        try saveState(p)
    }

    /// 프로젝트 폴더를 지운다. 폴더가 프로젝트 루트 바로 아래가 아니면 아무것도 하지 않고 던진다.
    /// `toTrash`면 휴지통으로 옮기고 휴지통 안의 위치를 돌려준다(목록의 삭제). 예전 형식 요약도 지울 수 있다.
    /// 원본 영상은 프로젝트 폴더 밖이라 건드리지 않는다.
    @discardableResult
    public func delete(_ summary: ProjectSummary, toTrash: Bool = false) throws -> URL? {
        try delete(folder: summary.folder, toTrash: toTrash)
    }

    @discardableResult
    public func delete(_ p: Project, toTrash: Bool = false) throws -> URL? {
        try delete(folder: p.folder, toTrash: toTrash)
    }

    private func delete(folder: URL, toTrash: Bool) throws -> URL? {
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProjectError.outsideRoot(folder)
        }
        if toTrash { return try trash(folder) }
        try fm.removeItem(at: folder)
        return nil
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
