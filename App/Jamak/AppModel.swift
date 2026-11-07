import AppKit
import AVFoundation
import Foundation
import JamakCore
import JamakMedia
import Observation
import UniformTypeIdentifiers

/// 사용자에게 그대로 보여 줄 문구를 가진 앱 오류.
enum AppError: LocalizedError {
    case mkvConversionFailed
    case unsupportedVideo
    case unsupportedRelinkVideo
    case durationMismatch
    case invalidLanguage
    case unreadableSRT
    case emptySRT
    case unplayableVideo
    case corruptProject
    case legacyProject
    case newerProject
    case corruptProjectState
    case invalidSubtitles
    case noSetSelected
    case sourceSetLocked
    case jobRunning

    var errorDescription: String? {
        switch self {
        case .mkvConversionFailed: "이 MKV는 변환할 수 없어요"
        case .unsupportedVideo: "mp4, mov, mkv 영상만 열 수 있어요"
        case .unsupportedRelinkVideo: "mp4나 mov 영상으로만 다시 지정할 수 있어요"
        case .durationMismatch: "길이가 다른 영상이에요"
        case .invalidLanguage: "언어 코드는 ko, ja, en 중 하나로 입력해 주세요"
        case .unreadableSRT: "자막 파일을 읽을 수 없어요. UTF-8로 저장된 srt만 지원해요."
        case .emptySRT: "자막 파일에서 자막을 찾지 못했어요."
        case .unplayableVideo: "재생할 수 없는 영상이에요"
        case .corruptProject: "자막 데이터(subtitles.json)를 읽을 수 없어요. 프로젝트를 열지 않았어요."
        case .legacyProject: "예전 형식이라 열 수 없어요"
        case .newerProject: "새 버전 앱에서 만든 프로젝트예요"
        case .corruptProjectState: "프로젝트 파일을 읽을 수 없어요"
        case .invalidSubtitles: "자막 데이터에 문제가 있어 저장하지 않았어요"
        case .noSetSelected: "자막을 가져올 자막셋을 먼저 골라 주세요"
        case .sourceSetLocked: AppModel.lockedNote
        case .jobRunning: "작업 중에는 자막을 가져올 수 없어요"
        }
    }
}

@MainActor @Observable
final class AppModel {
    // MARK: 상태

    private(set) var projects: [ProjectSummary] = []
    /// 연 프로젝트(마지막으로 저장한 내용). 지금 고치는 자막 데이터는 `editor`에 있다.
    var project: Project?
    /// 프로젝트 자막 데이터 전체(모든 자막셋)와 검토 티켓의 편집기. 실행 취소와 저장 안 된 변경의 단위다.
    var editor: SubtitleDataEditor?
    /// 지금 보고 고치는 자막셋.
    private(set) var currentSetID: UUID?
    /// 고른(기억한) 출력 언어. 자막셋마다 기억한다(project.json `outputLanguages`).
    private var chosenOutput: OutputLanguage = .all
    /// 영상 위·타임라인·검토 목록·세그먼트가 함께 쓰는 출력 언어. 지금 자막셋에 없는 언어(실행 취소나
    /// 언어 삭제로 사라진 언어)는 작품 원어로 맞춘다.
    var outputLanguage: OutputLanguage {
        guard let set = currentSet, let original = originalLanguage else { return chosenOutput }
        return set.resolvedOutput(chosenOutput, original: original)
    }
    var playheadMs: Int = 0
    var isPlaying: Bool = false
    /// 재생 속도. `playbackRates` 중 하나다. 프로젝트를 바꿔도 이어진다.
    private(set) var playbackRate: Float = 1
    /// 고를 수 있는 재생 속도.
    static let playbackRates: [Float] = [1, 1.25, 1.5, 2, 3]
    /// 열린 프로젝트의 영상을 찾지 못했다. 편집기 대신 "영상 찾기" 화면을 보여 준다.
    private(set) var videoMissing = false
    /// 사용자에게 띄울 경고 문구.
    var alertMessage: String?
    /// 저장 안 된 변경이 있는 상태에서 미뤄 둔 동작. 값이 있으면 저장 확인을 띄운다.
    private(set) var pendingAction: PendingAction?
    /// 새 프로젝트를 만들기 전에 묻는 "이 영상의 원문 언어". 값이 있으면 시트를 띄운다.
    private(set) var languageQuestion: LanguageQuestion?
    /// 이미 프로젝트가 있는 영상을 열 때 묻는 "기존 프로젝트 열기 / 새 프로젝트 만들기". 값이 있으면 확인 창을 띄운다.
    private(set) var existingProjectQuestion: ExistingProjectQuestion?
    /// 타임라인과 편집 패널에서 선택한 조각.
    private(set) var selectedCueID: UUID?
    /// 타임라인과 인스펙터에서 고른 장면 메모. 조각 선택과 함께 값을 갖지 않는다(하나를 고르면 다른 하나를 푼다).
    private(set) var selectedMemoID: UUID?
    /// 인스펙터에서 고치는 중인(아직 커밋하지 않은) 메모 글. 칸을 떠나거나 선택이 바뀌면 한 단계로 커밋한다.
    private(set) var memoDraft: MemoDraft? {
        didSet { if oldValue != nil, memoDraft == nil { Self.clearTextUndo() } }
    }
    /// 다음에 메모 편집기가 나타나거나 바뀔 때 글 칸에 포커스를 준다.
    var requestMemoFocus = false
    /// 편집 패널에서 고치는 중인(아직 커밋하지 않은) 조각 주석. 칸을 떠나거나 선택이 바뀌면 한 단계로 커밋한다.
    private(set) var noteDraft: NoteDraft? {
        didSet { if oldValue != nil, noteDraft == nil { Self.clearTextUndo() } }
    }
    /// 메모 레인을 숨겼다. `hiddenKinds`처럼 앱 실행 동안 전역이고 저장·내보내기에는 영향이 없다.
    var memosHidden = false
    /// 티켓 패널에서 고른 티켓(지금 자막셋). 처리되어 없어진 id일 수 있다(`selectedTicket`은 nil).
    var selectedTicketID: UUID?
    /// 티켓 상세의 주석 칸에 쓰던 글(티켓 id → 글). 티켓을 처리할 때 그 조각들의 주석에 덧붙이고 지운다.
    var ticketNotes: [UUID: String] = [:]
    /// 티켓 패널의 거르기. 언어는 자막셋마다 다를 수 있으니 쓸 때 `effectiveTicketFilter`로 푼다.
    var ticketFilter = TicketFilter()
    /// 편집 패널에서 고치는 중인(아직 커밋하지 않은) 본문. 초안이 끝나면(커밋하거나 버리면) 글 칸의 입력 실행 취소
    /// 기록을 지운다. 남겨 두면 다른 칸에서 누른 ⌘Z가 이미 커밋한 칸의 글을 되돌린다.
    private(set) var bodyDraft: BodyDraft? {
        didSet { if oldValue != nil, bodyDraft == nil { Self.clearTextUndo() } }
    }
    /// 다음에 편집 패널이 나타나거나 바뀔 때 본문에 포커스를 준다.
    var requestBodyFocus = false
    /// 파일 메뉴 "srt 가져오기…"를 눌렀다. 편집 화면이 파일을 고르게 하고 되돌린다.
    var srtImportRequested = false
    /// 눈금자를 끌어 고른 구간(ms). 값이 있으면 타임라인 위에 구간 작업 버튼을 보여 준다.
    var selectedRange: ClosedRange<Int>?
    /// 타임라인 줌(초당 픽셀).
    var pxPerSecond: Double = 60
    /// 열린 영상(원본)의 실제 위치. 내보내기 폴더의 기본값이 된다. 원본이 없어졌으면 nil.
    private(set) var videoURL: URL?
    /// 재생·오디오·프레임에 쓰는 영상. 변환본이 있으면 변환본(프로젝트 폴더), 없으면 원본.
    private(set) var mediaURL: URL?
    /// 작업 중이라 고칠 수 없는 자막셋. 생성기가 정한다.
    var lockedSetID: UUID?
    /// 지금 도는 작업(생성, 검토, 구간 작업)이 결과를 쓰는 자막셋. 생성기가 정한다.
    var jobSetID: UUID?
    /// 자막셋이 잠겨 있을 때 보여 주는 안내.
    nonisolated static let lockedNote = "자막을 만드는 중이라 이 자막셋은 잠겨 있어요"
    /// 지금 고치는 자막셋이 작업 중인 자막셋이라 고칠 수 없다.
    var isActiveSetLocked: Bool { lockedSetID != nil && lockedSetID == currentSetID }
    /// MKV 변환 진행률(0...1). 값이 있으면 변환 시트를 띄운다.
    private(set) var conversionProgress: Double?
    /// 숨긴 레인의 종류. 타임라인 그리기·클릭 판정과 영상 겹쳐 보기에서 뺀다.
    /// 앱 실행 동안 전역이다(자막셋·프로젝트를 바꿔도 유지). 저장·내보내기에는 영향이 없다.
    var hiddenKinds: Set<SubtitleKind> = []
    /// 타임라인 도구. 구간 도구면 레인 위 드래그도 구간 선택이다. 바꿔도 조각 선택은 그대로다.
    var timelineTool: TimelineTool = .select
    /// 조각 끌기의 100ms 스냅. 끄면 늘 ⌥를 누른 것과 같다.
    var snapEnabled = true
    /// 재생 중 타임라인을 재생 위치에 맞춰 옮기지 않는다("고정"). 켜면 재생 위치가 화면 밖으로 나가도 보던 곳을 그대로 둔다.
    var timelinePinned = false
    /// 인스펙터의 현재 탭. 제목 막대 "작품 노트"가 바꾼다.
    var inspectorTab: InspectorTab = .clip
    /// 인스펙터를 분할선으로 끌어 접었다. "작품 노트"가 다시 편다.
    var inspectorCollapsed = false
    /// 연 영상의 해상도와 fps. 영상을 열 때 한 번 읽는다. 읽기 전이거나 영상 트랙이 없으면 nil.
    private(set) var videoInfo: VideoInfo?
    /// 노트 패널의 글과 자동 저장.
    let notes = NotesEditing()
    /// LLM 요청 계측기. 연 프로젝트의 토큰 사용량을 들고 있다.
    let meter = LLMMeter()

    let player = AVPlayer()

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var scopedVideoURL: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// `openVideo`가 진행 중이다. 그동안 들어온 openVideo는 무시한다(같은 영상의 프로젝트가 둘 생기지 않게).
    private(set) var isOpeningVideo = false
    /// 진행 중인 MKV 변환. 시트의 "취소"가 이 작업을 취소한다.
    @ObservationIgnored private var conversionTask: Task<Int, Error>?
    /// 원문 언어 시트의 답을 기다리는 `openVideo`.
    @ObservationIgnored private var languageAnswer: CheckedContinuation<Language?, Never>?
    @ObservationIgnored private var existingProjectAnswer: CheckedContinuation<ExistingProjectChoice, Never>?
    /// 목록 읽기 차례. 늦게 끝난 예전 읽기가 새 목록을 덮지 않게 한다.
    @ObservationIgnored private var listToken = 0

    /// MKV를 변환한 영상의 프로젝트 폴더 안 이름.
    static let convertedVideoName = "video.mp4"

    init(root: URL = AppModel.defaultRoot()) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
        installObservers()
    }

    static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jamak", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    // MARK: 자막셋 보기

    /// 지금 자막셋(편집기의 내용).
    var currentSet: CueSet? { currentSetID.flatMap { editor?.set($0) } }

    /// 작품 원어: 프로젝트 하나에 하나다. 조각이 하나라도 있으면 바꿀 수 없다.
    var originalLanguage: Language? { project?.state.originalLanguage }

    /// 타임라인과 구간 작업, 생성이 쓰는 언어: 작품 원어. 인스펙터는 언어마다 칸을 따로 고친다.
    var editLanguage: Language? { originalLanguage }

    /// 지금 자막셋의 타임라인 보기(조각 id = Cue id): 출력 언어 글자, 빈 칸은 작품 원어. "전체"면 작품 원어.
    /// 재생 중 타임라인이 매 틱 읽으니 캐시한다(같은 배열을 돌려주면 비교도 바로 끝난다).
    var currentView: SubtitleSet { viewCache?.view ?? SubtitleSet(language: "") }

    /// 타임라인에서 출력 언어가 비어 작품 원어로 대신 보인 조각.
    var fallbackClipIDs: Set<UUID> { viewCache?.fallback ?? [] }

    /// 지금 자막셋의 언어 코드(내보내기 시트 등). 자막셋이 없으면 빈 배열.
    var languages: [String] { currentSet?.languages.map(\.rawValue) ?? [] }

    var isDirty: Bool { (editor?.isDirty ?? false) || hasDraftChanges }

    var durationMs: Int { project?.state.videoDurationMs ?? 0 }

    /// 지금 자막셋에서 타임라인에 보이는 칸에 의심 티켓이 있는 조각. 타임라인 배지에 쓴다.
    /// 출력 언어 하나면 그 언어 칸(빈 칸이라 작품 원어로 대신 보이면 작품 원어 칸)의 티켓, "전체"면 모든 언어.
    var flaggedClipIDs: Set<UUID> { viewCache?.flagged ?? [] }

    /// 지금 자막셋에서 타임라인에 보이는 칸에 고침 티켓이 있는 조각.
    var fixedClipIDs: Set<UUID> { viewCache?.fixed ?? [] }

    /// 보기 캐시의 키: 편집기, 그 상태 버전(데이터와 티켓), 자막셋, 출력 언어.
    private struct ViewCacheKey: Equatable {
        let editor: ObjectIdentifier
        let revision: UUID
        let setID: UUID
        let output: OutputLanguage
    }

    private struct ViewCache {
        let key: ViewCacheKey
        let view: SubtitleSet
        let fallback: Set<UUID>
        let flagged: Set<UUID>
        let fixed: Set<UUID>
    }

    @ObservationIgnored private var storedViewCache: ViewCache?

    /// 키가 같으면 저장한 보기를, 아니면 새로 만들어 돌려준다. 편집기의 `revision`, `currentSetID`,
    /// `outputLanguage`를 읽으니 그것이 바뀌면 화면이 다시 그려진다.
    private var viewCache: ViewCache? {
        guard let editor, let currentSetID, let set = editor.set(currentSetID), let original = originalLanguage
        else { return nil }
        let key = ViewCacheKey(editor: ObjectIdentifier(editor), revision: editor.revision, setID: currentSetID,
                               output: outputLanguage)
        if let cached = storedViewCache, cached.key == key { return cached }
        let timeline = set.timelineView(output: key.output, original: original)
        let book = editor.tickets
        // 타임라인에 보이는 칸의 티켓만 배지를 단다.
        func badged(_ level: Ticket.Level) -> Set<UUID> {
            guard case .one(let language) = key.output else { return book.cueIDs(set: currentSetID, level: level) }
            let shown = book.cueIDs(set: currentSetID, level: level, language: language)
            guard language != original, !timeline.fallback.isEmpty else { return shown }
            return shown.union(book.cueIDs(set: currentSetID, level: level, language: original)
                .intersection(timeline.fallback))
        }
        let made = ViewCache(key: key, view: timeline.view, fallback: timeline.fallback,
                             flagged: badged(.suspect), fixed: badged(.fix))
        storedViewCache = made
        return made
    }

    /// 지금 자막셋에서 조각의 `language` 칸에 열린 티켓.
    func ticket(for cueID: UUID, language: Language) -> Ticket? {
        guard let editor, let currentSetID else { return nil }
        return editor.tickets.ticket(set: currentSetID, cue: cueID, language: language)
    }

    /// 지금 자막셋의 언어별 채워진 조각 수(자막셋 탭 "n / 전체"). 편집기 상태 버전이 같으면 다시 세지 않는다.
    var filledCounts: [Language: Int] {
        guard let editor, let currentSetID, let set = editor.set(currentSetID) else { return [:] }
        let key = FilledCountsKey(editor: ObjectIdentifier(editor), revision: editor.revision, setID: currentSetID)
        if let cached = storedFilledCounts, cached.key == key { return cached.counts }
        var counts: [Language: Int] = [:]
        for language in set.languages { counts[language] = 0 }
        for cue in set.cues {
            for (language, text) in cue.texts where !text.isEmpty { counts[language, default: 0] += 1 }
        }
        storedFilledCounts = (key, counts)
        return counts
    }

    private struct FilledCountsKey: Equatable {
        let editor: ObjectIdentifier
        let revision: UUID
        let setID: UUID
    }

    @ObservationIgnored private var storedFilledCounts: (key: FilledCountsKey, counts: [Language: Int])?

    // MARK: 프로젝트

    /// 목록을 다시 읽는다. 목록 화면이 나타날 때마다 부른다. subtitles.json을 모두 읽으니 메인 밖에서 읽는다.
    func reloadProjects() async {
        listToken += 1
        let token = listToken
        let store = store
        let result = await Task.detached(priority: .userInitiated) { Result(catching: { try store.list() }) }.value
        guard token == listToken else { return }
        switch result {
        case .success(let list): projects = list
        case .failure(let error): projects = []; report(error)
        }
    }

    /// 프로젝트 폴더를 휴지통으로 옮기고 목록을 다시 읽는다. 원본 영상은 건드리지 않는다. 예전 형식과 깨진
    /// 프로젝트도 지운다. 새 버전 앱에서 만든 프로젝트는 지우지 않는다.
    func deleteProject(_ summary: ProjectSummary) async {
        guard summary.format != .newer else { return }
        do {
            try store.delete(summary, toTrash: true)
        } catch { report(error) }
        await reloadProjects()
    }

    /// 목록 카드용: 원본 영상(북마크 또는 경로)도 변환본도 찾을 수 없다. 파일 시스템을 읽으니 메인 밖에서 부른다.
    /// 예전 형식은 상태를 읽지 않으니 false.
    nonisolated static func isVideoMissing(_ summary: ProjectSummary) -> Bool {
        guard let state = summary.state else { return false }
        // 영상만 보니 자막 데이터는 비워 둔다.
        let project = Project(folder: summary.folder, state: state, subtitles: SubtitleData(sets: []))
        if convertedURL(of: project) != nil { return false }
        let store = ProjectStore(root: summary.folder.deletingLastPathComponent())
        return store.resolveVideo(project) == .missing
    }

    /// 영상을 골라 연다. 편집 중이면 저장 확인을 거친다(메뉴 "영상 열기…"와 목록의 "영상 열기"가 같이 쓴다).
    func chooseVideoAndOpen() {
        guard let url = FilePicker.chooseVideo(includeMKV: true) else { return }
        confirmDiscardingChanges {
            await self.perform { try await self.openVideo(url) }
        }
    }

    /// mp4/mov/mkv를 연다. 같은 영상의 프로젝트가 있으면 기존 것을 열지 새로 만들지 묻는다.
    /// 새로 만들 때는 원문 언어를 물은 뒤 만든다(취소하면 만들지 않는다). 새 프로젝트 이름은 "영상 이름 2"처럼 붙는다.
    /// mkv는 프로젝트 폴더의 mp4로 변환해서 연다(같은 영상 판별은 원본 mkv로 한다).
    /// 이미 다른 openVideo가 진행 중이면 아무것도 하지 않는다.
    func openVideo(_ url: URL) async throws {
        guard !isOpeningVideo else { return }
        isOpeningVideo = true
        defer { isOpeningVideo = false }
        try Self.checkVideoType(url, allowMKV: true)
        let store = store
        // 목록을 읽는 것과 같이 모든 subtitles.json을 읽으니 메인 밖에서 찾는다.
        let existing = try await Task.detached(priority: .userInitiated) {
            try store.findProject(forVideo: url)
        }.value
        if let existing {
            switch await askExistingProject(existing, video: url) {
            case .open:
                await open(existing)
                return
            case .cancel:
                return
            case .create:
                break
            }
        }
        // mkv는 AVFoundation이 읽지 못하니 길이는 변환한 뒤에 채운다.
        let durationMs = Self.isMKV(url) ? 0 : try await Self.loadDurationMs(url)
        guard let language = await askSourceLanguage(for: url) else { return }
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
        let created = try store.createProject(video: url, durationMs: durationMs, bookmark: bookmark, language: language)
        await open(created.summary, isNew: true)
    }

    /// 가장 최근에 시작한 열기. 늦게 끝난 이전 열기가 새 프로젝트를 덮지 않게 한다.
    @ObservationIgnored private var openToken = 0

    /// 자막 데이터를 읽어 프로젝트를 연다. 읽지 못하면 열지 않고 경고를 띄운다.
    func open(_ summary: ProjectSummary) async {
        await open(summary, isNew: false)
    }

    /// `isNew`: 방금 만든 프로젝트다. MKV 변환이 실패하거나 취소되면 프로젝트를 지운다.
    private func open(_ summary: ProjectSummary, isNew: Bool) async {
        let loaded: Project
        let store = store
        openToken += 1
        let token = openToken
        do {
            // subtitles.json(자막셋 여럿 × 조각 수천)을 읽고 푸니 메인 밖에서 한다.
            loaded = try await Task.detached(priority: .userInitiated) { try store.load(summary) }.value
            // 읽는 사이에 다른 프로젝트를 열기 시작했으면 이 결과는 버린다(나중에 끝난 쪽이 덮지 않게).
            guard token == openToken else { return }
        } catch ProjectError.corruptProject {
            report(AppError.corruptProject)
            return
        } catch ProjectError.legacyFormat {
            report(AppError.legacyProject)
            return
        } catch ProjectError.newerFormat {
            report(AppError.newerProject)
            return
        } catch ProjectError.corruptState {
            report(AppError.corruptProjectState)
            return
        } catch {
            report(error)
            return
        }
        closeProject()
        var p = loaded
        // 최근순 목록에서 맨 위로 오게 연 시각을 남긴다.
        p.state.lastOpenedAt = Date()
        var original: URL?
        if case .ok(let url, let isStale) = store.resolveVideo(p) {
            if url.startAccessingSecurityScopedResource() { scopedVideoURL = url }
            if isStale || url.path != p.state.videoPath {
                // 옮겨진 파일이나 낡은 북마크: 현재 위치로 상태와 북마크를 갱신한다.
                p.state.videoPath = url.path
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    p.state.videoFileSize = Int64(size)
                }
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                    p.state.videoBookmark = bookmark
                }
            }
            original = url
        }
        if let original, Self.isMKV(original), Self.convertedURL(of: p) == nil {
            do {
                p.state.videoDurationMs = try await convertMKV(original, into: p.folder)
                p.state.convertedVideoName = Self.convertedVideoName
            } catch {
                closeProject()
                if isNew { _ = try? store.delete(p) }
                if !(error is CancellationError) { report(error) }
                return
            }
        }
        do { try store.saveState(p) } catch { report(error) }
        meter.load(p.state.tokenUsage)
        self.project = p
        openNotes()
        // 원본이 없어져도 변환본이 있으면 변환본으로 연다.
        guard let media = Self.convertedURL(of: p) ?? original else {
            videoMissing = true
            return
        }
        videoURL = original
        mediaURL = media
        videoMissing = false
        loadVideoInfo(media)
        player.replaceCurrentItem(with: AVPlayerItem(url: media))
        editor = SubtitleDataEditor(data: p.subtitles, tickets: p.state.tickets ?? TicketBook(),
                                    original: p.state.originalLanguage)
        let initial = p.state.lastOpenedSetID.flatMap { p.subtitles.set(id: $0)?.id } ?? p.subtitles.sets.first?.id
        if let initial { switchSet(initial) }
    }

    /// 프로젝트를 닫고 목록으로 돌아간다.
    func closeProject() {
        saveTokenUsage()
        meter.load(nil)
        notes.close()
        player.pause()
        player.replaceCurrentItem(with: nil)
        scopedVideoURL?.stopAccessingSecurityScopedResource()
        scopedVideoURL = nil
        project = nil
        videoURL = nil
        mediaURL = nil
        videoInfo = nil
        currentSetID = nil
        chosenOutput = .all
        editor = nil
        storedViewCache = nil
        storedFilledCounts = nil
        selectedCueID = nil
        selectedMemoID = nil
        memoDraft = nil
        noteDraft = nil
        ticketNotes = [:]
        selectedTicketID = nil
        ticketFilter = TicketFilter()
        selectedRange = nil
        bodyDraft = nil
        requestBodyFocus = false
        requestMemoFocus = false
        // 다음 프로젝트는 펼친 인스펙터의 조각 탭으로 시작한다.
        inspectorTab = .clip
        inspectorCollapsed = false
        videoMissing = false
        isPlaying = false
        playheadMs = 0
    }

    /// 사라진 영상을 다시 지정한다. 길이가 다르면 `AppError.durationMismatch`.
    func relinkVideo(_ url: URL) async throws {
        guard var p = project else { return }
        try Self.checkVideoType(url, allowMKV: false)
        let durationMs = try await Self.loadDurationMs(url)
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
        do {
            try store.relink(&p, to: url, durationMs: durationMs, bookmark: bookmark)
        } catch ProjectError.durationMismatch {
            throw AppError.durationMismatch
        }
        await open(p.summary)
    }

    // MARK: 새 프로젝트의 원문 언어

    struct LanguageQuestion: Identifiable {
        let id = UUID()
        let videoName: String
        /// 설정의 원문 언어(없거나 읽지 못하면 기본값).
        let preselected: Language?
    }

    /// 원문 언어 시트의 답. nil이면 취소(프로젝트를 만들지 않는다). 시트의 버튼만 부른다.
    func answerLanguage(_ language: Language?) {
        languageQuestion = nil
        languageAnswer?.resume(returning: language)
        languageAnswer = nil
    }

    private func askSourceLanguage(for url: URL) async -> Language? {
        answerLanguage(nil)
        let preselected = GenerationController.preferredSourceLanguage
        return await withCheckedContinuation { continuation in
            languageAnswer = continuation
            languageQuestion = LanguageQuestion(videoName: url.lastPathComponent, preselected: preselected)
        }
    }

    // MARK: 같은 영상의 기존 프로젝트

    enum ExistingProjectChoice { case open, create, cancel }

    struct ExistingProjectQuestion: Identifiable {
        let id = UUID()
        let videoName: String
        /// 열 프로젝트(가장 최근에 연 것)의 이름.
        let projectName: String
    }

    /// 확인 창의 답. 확인 창의 버튼만 부른다(닫힘은 취소).
    func answerExistingProject(_ choice: ExistingProjectChoice) {
        existingProjectQuestion = nil
        existingProjectAnswer?.resume(returning: choice)
        existingProjectAnswer = nil
    }

    private func askExistingProject(_ existing: ProjectSummary, video: URL) async -> ExistingProjectChoice {
        answerExistingProject(.cancel)
        return await withCheckedContinuation { continuation in
            existingProjectAnswer = continuation
            existingProjectQuestion = ExistingProjectQuestion(videoName: video.lastPathComponent,
                                                              projectName: existing.name)
        }
    }

    // MARK: 프로젝트 이름

    /// 프로젝트 이름을 바꾼다. 폴더는 그대로 두고 project.json의 이름만 바꾼다. 비우면 영상 이름(폴더 이름)으로 돌아간다.
    /// 열려 있는 프로젝트는 들고 있는 상태에도 넣어 저장한다(그러지 않으면 다음 상태 저장이 옛 이름으로 덮는다).
    func renameProject(_ summary: ProjectSummary, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let p = project, p.folder.standardizedFileURL == summary.folder.standardizedFileURL {
                try updateState { $0.name = trimmed.isEmpty ? nil : trimmed }
            } else {
                try store.rename(summary, to: trimmed)
            }
        } catch {
            report(error)
        }
        await reloadProjects()
    }

    /// 제목 막대에서 이름 바꾸기 창을 띄울 프로젝트(열린 프로젝트). 편집 화면이 창을 띄운다.
    var renamingProject: ProjectSummary?

    /// 열려 있는 프로젝트의 이름을 바꾼다(제목 막대).
    func renameCurrentProject(to name: String) async {
        guard let summary = project?.summary else { return }
        await renameProject(summary, to: name)
    }

    // MARK: 자막셋

    /// 자막셋을 바꾼다. 자막 데이터는 프로젝트 전체가 한 편집기에 있으니 저장 확인 없이 바꾼다.
    /// 그 자막셋의 출력 언어를 고르고, 바뀌었으면 `lastOpenedSetID`를 저장한다(project.json만).
    func switchSet(_ id: UUID) {
        guard var p = project, editor?.set(id) != nil else { return }
        flushDraft()
        currentSetID = id
        chosenOutput = p.state.outputLanguages?[id] ?? .one(p.state.originalLanguage)
        selectedCueID = nil
        selectedMemoID = nil
        selectedTicketID = nil
        bodyDraft = nil
        if p.state.lastOpenedSetID != id {
            p.state.lastOpenedSetID = id
            project = p
            do { try store.saveState(p) } catch { report(error) }
        }
    }

    /// 작업(생성, 검토, 번역, 구간 작업)이 도는 중이다. 그동안은 자막셋을 더하거나 지우거나 이름을 바꾸지 않는다.
    /// 실행 취소가 막혀 있고 작업이 끝나면 기록을 비우니, 그 사이의 자막셋 변경은 되돌릴 수 없게 된다.
    /// 영상을 내보내는 중이다. 생성기가 정한다(내보내기는 자막셋을 잠그지 않지만 자막셋 구조는 바꾸지 않게 한다).
    var isExportingVideo = false
    /// 작업(생성, 검토, 번역, 구간 작업, 영상 내보내기)이 돌고 있다. 자막셋 구조 변경과 가져오기를 막는다.
    var isJobRunning: Bool { jobSetID != nil || lockedSetID != nil || isExportingVideo }

    /// 작업 중 자막셋 변경을 막을 때 보이는 안내.
    static let setsBlockedNote = "작업 중에는 자막셋을 더하거나 지우거나 이름을 바꿀 수 없어요"

    /// 새 자막셋을 더하고 그 자막셋으로 바꾼다. 언어는 지금 자막셋과 같고 조각은 없다.
    func addSet(named name: String) {
        guard !isJobRunning, let editor, let currentSetID else { return }
        flushDraft()
        let id = editor.addSet(name: name, like: currentSetID)
        switchSet(id)
    }

    /// 자막셋을 조각째 복제하고("<이름> 사본") 그 자막셋으로 바꾼다.
    func duplicateSet(_ id: UUID) {
        guard !isJobRunning, let editor, let source = editor.set(id) else { return }
        flushDraft()
        do {
            let copy = try editor.duplicateSet(id, name: Self.copyName(source.name))
            switchSet(copy)
        } catch { report(error) }
    }

    /// 복제한 자막셋의 이름.
    static func copyName(_ name: String) -> String { "\(name) 사본" }

    func renameSet(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isJobRunning, !trimmed.isEmpty else { return }
        flushDraft()
        editor?.renameSet(id, to: trimmed)
    }

    /// 자막셋을 지운다(실행 취소할 수 있다). 마지막 하나는 지우지 않고, 작업 중에는 아무것도 지우지 않는다.
    /// 지금 자막셋이었으면 첫 자막셋으로 바꾼다.
    func deleteSet(_ id: UUID) {
        guard let editor, canDeleteSet(id) else { return }
        flushDraft()
        do {
            try editor.deleteSet(id)
        } catch { report(error) }
        dropStaleSelection()
    }

    /// 자막셋이 둘 이상이고, 작업이 돌고 있지 않다.
    func canDeleteSet(_ id: UUID) -> Bool {
        !isJobRunning && (editor?.data.sets.count ?? 0) > 1
    }

    /// 지금 자막셋의 출력 언어를 바꾸고 기억한다(project.json만). 기억한 값과 비교한다(기억한 값이 지운 언어라
    /// 작품 원어로 보이는 중에 작품 원어를 고르면 그 값을 새로 기억해야 한다).
    func setOutputLanguage(_ output: OutputLanguage) {
        guard let currentSetID, output != chosenOutput else { return }
        chosenOutput = output
        do {
            try updateState { state in
                var all = state.outputLanguages ?? [:]
                all[currentSetID] = output
                state.outputLanguages = all
            }
        } catch { report(error) }
    }

    // MARK: 자막셋 언어

    /// 작업 중 자막셋 탭(이름, 언어)을 막을 때 보이는 안내.
    static let setSettingsBlockedNote = "작업 중에는 이름을 바꾸거나 언어를 더하거나 지울 수 없어요"

    /// 지금 자막셋에 언어를 더한다(모든 조각에 빈 칸이 생긴다). 실행 취소할 수 있다. 작업 중에는 하지 않는다.
    func addLanguage(_ language: Language) {
        guard !isJobRunning, let editor, let currentSetID else { return }
        flushDraft()
        do { try editor.addLanguage(language, to: currentSetID) } catch { report(error) }
    }

    /// 지금 자막셋에서 언어를 지운다(그 언어 문장과 표시도 함께). 실행 취소할 수 있다. 작품 원어는 지우지 않는다.
    /// 보통은 조각 탭을 떠날 때 고치던 본문이 이미 커밋돼 있다(지운 언어를 되돌리면 그 글도 돌아온다).
    /// 그래도 그 언어 칸의 초안이 남아 있으면 지울 언어에 커밋하지 않고 버린다(안전장치).
    func removeLanguage(_ language: Language) {
        guard !isJobRunning, let editor, let currentSetID, let original = originalLanguage,
              language != original else { return }
        if let draft = bodyDraft, draft.setID == currentSetID, draft.language == language { bodyDraft = nil }
        flushDraft()
        do { try editor.removeLanguage(language, original: original, from: currentSetID) } catch { report(error) }
    }

    /// 작품 원어를 바꾼다. 조각이 하나라도 있으면 던진다(`originalLanguageLocked`). 자막셋 언어를 맞추고
    /// 프로젝트 상태와 함께 바로 저장한다. 조각이 없을 때만 되니 잃는 것이 없어, 실행 취소 기록은 비운다.
    func changeOriginalLanguage(to language: Language) {
        guard !isJobRunning, let editor, let old = originalLanguage, old != language else { return }
        flushDraft()
        do {
            try editor.changeOriginalLanguage(from: old, to: language)
        } catch {
            report(error)
            return
        }
        do {
            try persist { $0.originalLanguage = language }
            editor.setOriginal(language)
            editor.clearHistory()
        } catch {
            editor.undoManager.undo()
            report(error)
        }
    }

    /// 프로젝트 자막 데이터 전체와 검토 티켓을 저장한다(subtitles.json 다음 project.json).
    func save() throws {
        flushDraft()
        try persist()
    }

    /// 편집기의 내용과 티켓을 상태 변경과 함께 저장하고 저장된 상태로 표시한다.
    /// 지운 자막셋의 진행 기록·출력 언어와 없는 조각·언어의 표시는 이때 버리고(`ProjectState.prune`),
    /// 지운 자막셋의 LLM 중간 저장(`work/<자막셋 id>/`)은 저장한 뒤 메인 밖에서 지운다.
    /// 저장 전에는 남겨 두니 자막셋 삭제를 실행 취소하면 진행도 그대로다.
    private func persist(changingState change: (inout ProjectState) -> Void = { _ in }) throws {
        guard var p = project, let editor else { return }
        change(&p.state)
        p.subtitles = editor.data
        p.state.tickets = editor.tickets.tickets.isEmpty && p.state.tickets == nil ? nil : editor.tickets
        p.state.prune(to: p.subtitles)
        do {
            try store.save(p)
        } catch ProjectError.invalidSubtitles {
            // 불변식을 어긴 데이터를 쓰면 다음에 열 수 없다. 쓰지 않고 알린다(편집기 내용은 그대로 남는다).
            throw AppError.invalidSubtitles
        }
        // 폴더 목록 하나를 읽을 뿐이라 저장마다 한다(이 수정 전에 지운 자막셋의 것도 치운다).
        let store = store, saved = p
        Task.detached(priority: .utility) { store.removeOrphanWork(saved) }
        project = p
        editor.markSaved()
    }

    /// 가져오기 계획: srt를 읽어 지금 자막셋과 견준 결과. 확인 질문(언어 추가, 덮어쓰기)에 쓴다.
    struct SRTImportPlan {
        let clips: [SubtitleClip]
        let setID: UUID
        let language: Language
        /// 자막셋에 없는 언어라 가져오면서 더한다.
        let addsLanguage: Bool
        /// 이미 다른 문장이 있어 덮어쓰게 되는 조각 수.
        let overwrites: Int
    }

    /// srt를 읽어 지금 자막셋의 `language` 칸에 넣을 계획을 세운다(바꾸지 않는다). 작업 중이면 던진다.
    /// 고치던 본문은 먼저 커밋한다(그대로 두면 계획에서 빠지고 가져온 뒤 덮일 수 있다).
    func planSRTImport(_ url: URL, language: Language) throws -> SRTImportPlan {
        guard !isJobRunning else { throw AppError.jobRunning }
        guard let setID = currentSetID, let set = currentSet else { throw AppError.noSetSelected }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // 읽지 못한 파일로 멀쩡한 칸을 덮어쓰지 않도록 먼저 거른다.
        guard String(data: data, encoding: .utf8) != nil else { throw AppError.unreadableSRT }
        let clips = SRTCodec.parse(data)
        guard !clips.isEmpty else { throw AppError.emptySRT }
        flushDraft()
        let plan = CueSRT.importPlan(clips, into: currentSet ?? set, language: language)
        return SRTImportPlan(clips: clips, setID: setID, language: language,
                             addsLanguage: !set.languages.contains(language), overwrites: plan.overwrites)
    }

    /// 계획대로 가져온다. 없는 언어는 같은 실행 취소 단계에서 더한다. 저장하지 않는다(실행 취소할 수 있다).
    /// 확인을 기다리는 사이 자막셋이 바뀌었을 수 있어 지금 상태로 다시 짝짓는다.
    func importSRT(_ plan: SRTImportPlan) throws {
        guard !isJobRunning else { throw AppError.jobRunning }
        flushDraft()
        guard let editor, let set = editor.set(plan.setID) else { return }
        let result = CueSRT.importPlan(plan.clips, into: set, language: plan.language)
        let added = result.newCues.map {
            SubtitleClip(id: $0.id, start: $0.start, end: $0.end, kind: $0.kind, text: $0.text(plan.language))
        }
        let write = CueWrite(language: plan.language, adding: added, texts: result.filled)
        editor.apply(write, to: plan.setID, actionName: "srt 가져오기")
        dropStaleSelection()
    }

    /// 파일 이름 끝의 `.xx.srt`가 가리키는 언어. 없으면 nil.
    static func defaultLanguage(forSRT url: URL) -> Language? {
        Language(rawValue: url.deletingPathExtension().pathExtension.lowercased())
    }

    // MARK: AI 작업

    /// 작업이 쓰는 자막셋: 작업 중이면 작업의 자막셋, 아니면 지금 자막셋.
    var generationSetID: UUID? { jobSetID ?? currentSetID }

    /// 작업이 쓰는 자막셋(편집기의 내용).
    var generationSet: CueSet? { generationSetID.flatMap { editor?.set($0) } }

    /// 작업 자막셋의 한 언어 보기(조각 id = Cue id, 타임라인 순서). 파이프라인 입력이다(설계 11.1).
    /// 고치던 본문을 먼저 커밋한다. `nonEmpty`면 그 언어 칸이 빈 조각은 뺀다. 자막셋이 없으면 nil.
    func jobView(_ language: Language, nonEmpty: Bool = true) -> SubtitleSet? {
        flushDraft()
        guard let set = generationSet else { return nil }
        let view = set.view(language: language)
        let clips = view.clips.filter { !nonEmpty || !$0.text.isEmpty }.sorted(by: SubtitleClip.timelineOrder)
        return SubtitleSet(language: view.language, clips: clips)
    }

    /// 작업 결과를 작업 자막셋에 한 단계로 되쓰고(없는 언어는 같은 단계에서 더한다) 상태 변경과 함께 바로 저장한다.
    /// 저장한 작업 단계는 진행 기록과 함께 저장됐으니 실행 취소로 되돌리지 않는다(기록을 비운다).
    func applyJobWrite(_ write: CueWrite, actionName: String,
                       state change: (inout ProjectState) -> Void = { _ in }) throws {
        flushDraft()
        guard let editor, let setID = generationSetID, editor.set(setID) != nil else { return }
        editor.apply(write, to: setID, actionName: actionName)
        try persist(changingState: change)
        editor.clearHistory()
        dropStaleSelection()
    }

    /// 작업 결과를 실행 취소 한 단계로 되쓴다(저장하지 않는다). 생성기만 부른다(조각 번역).
    /// 그사이 편집기가 바뀌었거나 자막셋이 없어졌으면 넣지 않고 false를 돌려준다.
    @discardableResult
    func applyUndoableWrite(_ write: CueWrite, to editor: SubtitleDataEditor, set setID: UUID,
                            actionName: String) -> Bool {
        guard self.editor === editor, editor.set(setID) != nil else { return false }
        if let draft = bodyDraft, write.removing.contains(draft.cueID) { bodyDraft = nil }
        flushDraft()
        editor.apply(write, to: setID, actionName: actionName)
        dropStaleSelection()
        return true
    }

    /// 구간 작업의 결과를 `set`의 작품 원어 칸에 실행 취소 한 단계로 넣는다(저장하지 않는다). 생성기만 부른다.
    /// 바꾸는 조각의 다른 언어 문장은 `RangeWrite`가 결과 조각으로 옮긴다(1:1이면 id를 그대로, 아니면 확인 티켓과 함께).
    /// 그사이 편집기가 바뀌었거나 자막셋이 없어졌으면 넣지 않고 false를 돌려준다.
    @discardableResult
    func applyRangeResult(to editor: SubtitleDataEditor, set setID: UUID, removing: Set<UUID>,
                          adding: [SubtitleClip], actionName: String) -> Bool {
        guard self.editor === editor, let set = editor.set(setID), let original = originalLanguage else { return false }
        if let draft = bodyDraft, removing.contains(draft.cueID) { bodyDraft = nil }
        let write = RangeWrite.replacing(removing, with: adding, language: original, in: set)
        editor.apply(write, to: setID, actionName: actionName)
        dropStaleSelection()
        return true
    }

    /// 프로젝트 상태(project.json)만 바꿔 저장한다. 자막의 저장 안 된 변경은 건드리지 않는다.
    func updateState(_ change: (inout ProjectState) -> Void) throws {
        guard var p = project else { return }
        change(&p.state)
        guard p.state != project?.state else { return }
        try store.saveState(p)
        project = p
    }

    /// 계측기의 토큰 사용량을 project.json에 저장한다. 바뀐 것이 없으면 쓰지 않는다(쓴 적 없는 빈 사용량도 쓰지 않는다).
    func saveTokenUsage() {
        let book = meter.usage
        do {
            try updateState { state in
                guard state.tokenUsage != nil || !book.tasks.isEmpty else { return }
                state.tokenUsage = book
            }
        } catch {
            report(error)
        }
    }

    /// 저장하지 않은 변경을 버리고 저장된 자막 데이터로 편집기를 다시 만든다.
    func discardUnsavedChanges() {
        bodyDraft = nil
        noteDraft = nil
        memoDraft = nil
        guard isDirty, let p = project else { return }
        editor = SubtitleDataEditor(data: p.subtitles, tickets: p.state.tickets ?? TicketBook(),
                                    original: p.state.originalLanguage)
        if let currentSetID, p.subtitles.set(id: currentSetID) == nil {
            self.currentSetID = nil
            if let first = p.subtitles.sets.first?.id { switchSet(first) }
        }
        dropStaleSelection()
    }

    /// 모든 프로젝트의 프레임 캐시(`frames/`)를 지우고 자막셋마다 `framesCapturedUpTo`를 -1로 되돌린다.
    /// 화면 글자 조각은 자막셋에 이미 있으니 `textRecognized`는 그대로 둔다. 목록 읽기와 지우기는 메인 밖에서 한다.
    func clearFrameCaches() async throws {
        let store = store
        let summaries = try await Task.detached(priority: .userInitiated) { () throws -> [ProjectSummary] in
            let list = try store.list()
            for summary in list {
                try? FileManager.default.removeItem(
                    at: summary.folder.appendingPathComponent(AppModel.framesFolderName, isDirectory: true))
            }
            return list
        }.value
        for summary in summaries {
            guard let state = summary.state, state.setGeneration?.isEmpty == false else { continue }
            if summary.folder.standardizedFileURL == project?.folder.standardizedFileURL {
                try updateState { Self.resetFrames(&$0) }
            } else {
                var changed = state
                Self.resetFrames(&changed)
                // project.json만 쓰니 자막 데이터는 비워 둔다.
                try store.saveState(Project(folder: summary.folder, state: changed,
                                            subtitles: SubtitleData(sets: [])))
            }
        }
    }

    private static func resetFrames(_ state: inout ProjectState) {
        guard var all = state.setGeneration else { return }
        for key in all.keys { all[key]?.framesCapturedUpTo = -1 }
        state.setGeneration = all
    }

    /// 프로젝트 폴더 안 프레임 캐시 폴더 이름.
    nonisolated static let framesFolderName = "frames"
    /// 프로젝트 폴더 안 오디오 캐시 이름.
    nonisolated static let audioFileName = "audio.wav"

    // MARK: 저장 확인

    struct PendingAction {
        let run: @MainActor () async -> Void
        let cancel: @MainActor () -> Void
    }

    /// 저장 안 된 변경이 있으면 동작을 미루고 저장 확인을 띄운다. 없으면 바로 실행한다.
    /// `onCancel`은 사용자가 취소했거나 저장에 실패했을 때 부른다.
    func confirmDiscardingChanges(then action: @escaping @MainActor () async -> Void,
                                  onCancel: @escaping @MainActor () -> Void = {}) {
        flushDraft()
        if isDirty {
            // 이미 떠 있는 확인이 있으면 그 동작은 취소로 끝낸다.
            pendingAction?.cancel()
            pendingAction = PendingAction(run: action, cancel: onCancel)
        } else {
            Task { await action() }
        }
    }

    /// 저장 확인의 답. 확인 창의 버튼만 부른다(창이 닫히는 순서와 무관하게 동작한다).
    /// `save == true`: 저장 후 진행, `false`: 버리고 진행, `nil`: 취소.
    func resolvePendingAction(save: Bool?) {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        guard let save else { pending.cancel(); return }
        if save {
            do { try self.save() } catch { report(error); pending.cancel(); return }
        }
        Task { await pending.run() }
    }

    /// 저장 확인을 거쳐 프로젝트 목록으로 돌아간다.
    func requestCloseProject() {
        confirmDiscardingChanges { self.closeProject() }
    }

    /// 저장하고, 실패하면 경고를 띄운다.
    func saveReportingErrors() {
        do { try save() } catch { report(error) }
    }

    // MARK: 편집

    /// 고치는 중인 한 칸의 본문.
    struct BodyDraft: Equatable {
        let setID: UUID
        let cueID: UUID
        let language: Language
        var text: String
    }

    /// 선택한 조각(모든 언어).
    var selectedCue: Cue? {
        guard let id = selectedCueID else { return nil }
        return currentSet?.cues.first { $0.id == id }
    }

    /// 선택한 조각의 고치는 언어 보기.
    var selectedClip: SubtitleClip? {
        guard let id = selectedCueID, let set = currentSet, let language = editLanguage,
              let cue = set.cues.first(where: { $0.id == id }) else { return nil }
        return SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind, text: cue.text(language))
    }

    /// 선택을 바꾼다. 고치던 본문은 먼저 커밋한다. 고른 메모가 있으면 푼다(nil이어도).
    func select(_ id: UUID?) {
        guard id != selectedCueID || selectedMemoID != nil else { return }
        flushDraft()
        selectedMemoID = nil
        selectedCueID = id
        adoptTicket(containing: id)
    }

    /// 인스펙터 언어 칸에 보여 줄 글. 그 칸을 고치는 중이면 그 글. 빈 칸은 빈 문자열이다(작품 원어로 채우지 않는다).
    func bodyText(of cue: Cue, language: Language) -> String {
        if let bodyDraft, bodyDraft.cueID == cue.id, bodyDraft.setID == currentSetID,
           bodyDraft.language == language { return bodyDraft.text }
        return cue.text(language)
    }

    /// 한 칸을 고치는 중인 글로 둔다. 다른 칸을 고치던 글이 있으면 먼저 커밋한다(칸마다 한 단계).
    func setBodyDraft(_ text: String, for cueID: UUID, language: Language) {
        guard !isActiveSetLocked, let currentSetID, currentSet?.languages.contains(language) == true else { return }
        if let draft = bodyDraft, draft.setID != currentSetID || draft.cueID != cueID || draft.language != language {
            flushDraft()
        }
        bodyDraft = BodyDraft(setID: currentSetID, cueID: cueID, language: language, text: text)
    }

    /// 고치던 본문(과 메모 글)을 한 번의 편집으로 커밋한다. 바뀐 게 없으면 버린다.
    func flushDraft() {
        flushMemoDraft()
        flushNoteDraft()
        guard let draft = bodyDraft else { return }
        bodyDraft = nil
        guard draft.setID != lockedSetID, let editor,
              let cue = editor.set(draft.setID)?.cues.first(where: { $0.id == draft.cueID }),
              cue.text(draft.language) != draft.text else { return }
        editor.setText(draft.text, cue: draft.cueID, language: draft.language, in: draft.setID, actionName: "문장 수정")
    }

    private var hasDraftChanges: Bool {
        if let draft = noteDraft,
           let cue = editor?.set(draft.setID)?.cues.first(where: { $0.id == draft.cueID }),
           cue.note != draft.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return true
        }
        if let draft = memoDraft,
           let memo = editor?.set(draft.setID)?.memos.first(where: { $0.id == draft.memoID }), memo.text != draft.text {
            return true
        }
        guard let draft = bodyDraft,
              let cue = editor?.set(draft.setID)?.cues.first(where: { $0.id == draft.cueID }) else { return false }
        return cue.text(draft.language) != draft.text
    }

    /// 조각의 시간과 종류만 바꾼다(본문은 그대로). 바뀐 게 없으면 아무것도 하지 않는다.
    func commitTiming(_ clip: SubtitleClip, actionName: String) {
        flushDraft()
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        editor.updateTiming(Cue(id: clip.id, start: clip.start, end: clip.end, kind: clip.kind),
                            in: currentSetID, actionName: actionName)
    }

    /// 빈 레인을 더블클릭한 자리에 1000ms짜리 조각(모든 언어 빈 칸)을 만들고 본문에 포커스를 준다.
    func addClip(kind: SubtitleKind, at ms: Int) {
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        let length = 1000
        let limit = max(durationMs, length)
        let start = max(0, min(ms, limit - length))
        let cue = Cue(start: start, end: start + length, kind: kind)
        flushDraft()
        editor.addCue(cue, to: currentSetID)
        selectedMemoID = nil
        selectedCueID = cue.id
        showClipInspector()
        requestBodyFocus = true
    }

    /// 고른 조각이나 메모를 지운다(⌫).
    func deleteSelected() {
        if selectedMemoID != nil {
            deleteSelectedMemo()
            return
        }
        guard !isActiveSetLocked, let id = selectedCueID, let editor, let currentSetID else { return }
        // 숨긴 레인의 조각은 지우지 않는다(숨길 때 선택을 풀지만 한 번 더 막는다).
        if let kind = selectedClip?.kind, hiddenKinds.contains(kind) { return }
        if bodyDraft?.cueID == id { bodyDraft = nil }
        editor.deleteCue(id, in: currentSetID)
        selectedCueID = nil
    }

    /// 지금 자막셋에서 그 트랙의 조각을 모두 지운다(실행 취소 한 단계). 잠긴 자막셋이면 아무것도 하지 않는다.
    func clearTrack(_ kind: SubtitleKind) {
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        flushDraft()
        if let selected = selectedClip, selected.kind == kind {
            if bodyDraft?.cueID == selected.id { bodyDraft = nil }
            selectedCueID = nil
        }
        editor.deleteCues(ofKind: kind, in: currentSetID)
    }

    // MARK: 조각 주석

    /// 고치는 중인 조각 주석.
    struct NoteDraft: Equatable {
        let setID: UUID
        let cueID: UUID
        var text: String
    }

    /// 편집 패널에 보일 주석(고치는 중이면 그 글).
    func noteText(of cue: Cue) -> String {
        if let noteDraft, noteDraft.cueID == cue.id, noteDraft.setID == currentSetID { return noteDraft.text }
        return cue.note
    }

    /// 주석을 고치는 중인 글로 둔다. 다른 조각을 고치던 글이 있으면 먼저 커밋한다.
    func setNoteDraft(_ text: String, for cueID: UUID) {
        guard !isActiveSetLocked, let currentSetID else { return }
        if let draft = noteDraft, draft.setID != currentSetID || draft.cueID != cueID { flushNoteDraft() }
        noteDraft = NoteDraft(setID: currentSetID, cueID: cueID, text: text)
    }

    /// 고치던 주석을 한 번의 편집("주석 고치기")으로 커밋한다. 바뀐 게 없으면 버린다.
    private func flushNoteDraft() {
        guard let draft = noteDraft else { return }
        noteDraft = nil
        guard draft.setID != lockedSetID, let editor,
              let cue = editor.set(draft.setID)?.cues.first(where: { $0.id == draft.cueID }),
              cue.note != draft.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        editor.setNote(draft.text, cue: draft.cueID, in: draft.setID)
    }

    /// 지금 자막셋 조각 칸의 검토됨을 켜거나 끈다(실행 취소 한 단계).
    func setReviewed(_ on: Bool, cue cueID: UUID, language: Language) {
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        flushDraft()
        editor.setReviewed(on, cue: cueID, language: language, in: currentSetID)
    }

    // MARK: 장면 메모

    /// 고치는 중인 메모 글.
    struct MemoDraft: Equatable {
        let setID: UUID
        let memoID: UUID
        var text: String
    }

    /// 새 메모의 길이(ms). 장면 하나쯤을 덮는다.
    static let newMemoLengthMs = 5000

    /// 고른 메모(지금 자막셋).
    var selectedMemo: SceneMemo? {
        guard let id = selectedMemoID else { return nil }
        return currentSet?.memos.first { $0.id == id }
    }

    /// 메모를 고른다(nil이면 푼다). 고른 조각은 푼다. 고치던 글은 먼저 커밋한다.
    func selectMemo(_ id: UUID?) {
        guard id != selectedMemoID else { return }
        flushDraft()
        selectedCueID = nil
        selectedMemoID = id
    }

    /// 인스펙터 메모 칸에 보여 줄 글. 그 메모를 고치는 중이면 그 글.
    func memoText(of memo: SceneMemo) -> String {
        if let memoDraft, memoDraft.memoID == memo.id, memoDraft.setID == currentSetID { return memoDraft.text }
        return memo.text
    }

    /// 메모 글을 고치는 중인 글로 둔다. 다른 메모를 고치던 글이 있으면 먼저 커밋한다.
    func setMemoDraft(_ text: String, for memoID: UUID) {
        guard !isActiveSetLocked, let currentSetID else { return }
        if let draft = memoDraft, draft.setID != currentSetID || draft.memoID != memoID { flushMemoDraft() }
        memoDraft = MemoDraft(setID: currentSetID, memoID: memoID, text: text)
    }

    /// 고치던 메모 글을 한 번의 편집("메모 수정")으로 커밋한다. 바뀐 게 없으면 버린다.
    private func flushMemoDraft() {
        guard let draft = memoDraft else { return }
        memoDraft = nil
        guard draft.setID != lockedSetID, let editor,
              var memo = editor.set(draft.setID)?.memos.first(where: { $0.id == draft.memoID }),
              memo.text != draft.text else { return }
        memo.text = draft.text
        editor.updateMemo(memo, in: draft.setID, actionName: "메모 수정")
    }

    /// 빈 메모 레인을 더블클릭한 자리(또는 재생 위치)에 메모를 만들고 글 칸에 포커스를 준다.
    func addMemo(at ms: Int) {
        let length = Self.newMemoLengthMs
        let limit = max(durationMs, length)
        let start = max(0, min(ms, limit - length))
        addMemo(range: start...(start + length))
    }

    /// 그 시간 범위로 메모를 만들어 고르고 글 칸에 포커스를 준다. 너무 짧으면 최소 길이로 늘린다.
    func addMemo(range: ClosedRange<Int>) {
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        flushDraft()
        let length = max(range.upperBound - range.lowerBound, ClipDrag.minLengthMs)
        let limit = max(durationMs, range.upperBound, length)
        let start = max(0, min(range.lowerBound, limit - length))
        let memo = SceneMemo(start: start, end: start + length, text: "")
        editor.addMemo(memo, to: currentSetID)
        memosHidden = false
        selectedCueID = nil
        selectedMemoID = memo.id
        showClipInspector()
        requestMemoFocus = true
    }

    /// 구간·조각 칩의 "메모": 그 시간과 겹치는 메모가 있으면 고르고, 없으면 그 시간으로 새 메모를 만든다.
    func openMemo(for range: ClosedRange<Int>) {
        if let memo = currentSet?.memos(overlapping: range).first {
            memosHidden = false
            selectMemo(memo.id)
            showClipInspector()
            requestMemoFocus = true
        } else {
            addMemo(range: range)
        }
    }

    /// 메모의 시간을 바꾼다(글은 고치던 글을 먼저 커밋한 그대로). 바뀐 게 없으면 아무것도 하지 않는다.
    func commitMemo(_ memo: SceneMemo, actionName: String) {
        flushDraft()
        guard !isActiveSetLocked, let editor, let currentSetID,
              var current = currentSet?.memos.first(where: { $0.id == memo.id }),
              current.start != memo.start || current.end != memo.end else { return }
        current.start = memo.start
        current.end = memo.end
        editor.updateMemo(current, in: currentSetID, actionName: actionName)
    }

    /// 고른 메모를 지운다. 숨긴 메모 레인의 메모는 지우지 않는다.
    func deleteSelectedMemo() {
        guard !isActiveSetLocked, !memosHidden, let id = selectedMemoID, let editor, let currentSetID else { return }
        if memoDraft?.memoID == id { memoDraft = nil }
        editor.deleteMemo(id, in: currentSetID)
        selectedMemoID = nil
    }

    /// 지금 자막셋의 메모를 모두 지운다(실행 취소 한 단계).
    func clearMemos() {
        guard !isActiveSetLocked, let editor, let currentSetID else { return }
        flushDraft()
        selectedMemoID = nil
        editor.clearMemos(in: currentSetID)
    }

    /// 트랙 머리 메모 레인의 눈 버튼. 숨기면 고른 메모를 푼다.
    func setMemosHidden(_ hidden: Bool) {
        guard hidden != memosHidden else { return }
        if hidden, selectedMemoID != nil { selectMemo(nil) }
        memosHidden = hidden
    }

    func fixOverlap(_ overlap: Overlap) {
        flushDraft()
        guard !isActiveSetLocked, let currentSetID else { return }
        editor?.fixOverlap(overlap, in: currentSetID)
    }

    /// 실행 취소는 프로젝트 전체 단위라, 작업 중인 자막셋이 있으면 막는다(작업 결과가 섞이지 않게).
    /// 다른 자막셋이 바뀌었으면 그 자막셋으로 바꿔 바뀐 것이 보이게 한다.
    func undo() {
        flushDraft()
        guard lockedSetID == nil, let editor, editor.undoManager.canUndo else { return }
        stepHistory(editor) { $0.undoManager.undo() }
    }

    func redo() {
        flushDraft()
        guard lockedSetID == nil, let editor, editor.undoManager.canRedo else { return }
        stepHistory(editor) { $0.undoManager.redo() }
    }

    private func stepHistory(_ editor: SubtitleDataEditor, _ step: (SubtitleDataEditor) -> Void) {
        let before = (data: editor.data, tickets: editor.tickets)
        step(editor)
        let changed = SubtitleDataEditor.changedSets(from: before.data, before.tickets, to: editor.data, editor.tickets)
        if let currentSetID, editor.set(currentSetID) != nil, !changed.contains(currentSetID),
           let target = editor.data.sets.first(where: { changed.contains($0.id) }) {
            switchSet(target.id)
        }
        dropStaleSelection()
    }

    /// 실행 취소·복귀로 선택한 조각(또는 지금 자막셋)이 사라졌으면 선택을 푼다.
    func dropStaleSelection() {
        if let currentSetID, editor?.set(currentSetID) == nil, let first = editor?.data.sets.first?.id {
            switchSet(first)
        }
        if selectedCueID != nil, selectedClip == nil { selectedCueID = nil }
        if selectedMemoID != nil, selectedMemo == nil {
            selectedMemoID = nil
            memoDraft = nil
        }
    }

    func zoom(by factor: Double) {
        let range = TimelineGeometry.pxPerSecondRange
        pxPerSecond = min(max(pxPerSecond * factor, range.lowerBound), range.upperBound)
    }

    // MARK: 내보내기

    var exportVideoName: String {
        videoURL?.lastPathComponent ?? URL(fileURLWithPath: project?.state.videoPath ?? "video").lastPathComponent
    }

    /// 지금 자막셋에 있는 언어만 `영상이름.<언어코드>.srt`로 나간다.
    private func exportLanguages(_ codes: [Language]) -> [Language] {
        let available = currentSet?.languages ?? []
        return codes.filter(available.contains)
    }

    func exportConflicts(languages: [Language], in folder: URL) -> [URL] {
        SRTExporter.conflicts(languages: exportLanguages(languages), videoName: exportVideoName, in: folder)
    }

    /// 지금 자막셋(편집기의 내용)을 언어마다 srt로 쓴다. `fallback`이면 빈 칸을 작품 원어로 채운다.
    func export(languages: [Language], fallback: Bool, to folder: URL) throws -> [URL] {
        flushDraft()
        guard let set = currentSet, let original = originalLanguage else { return [] }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return try SRTExporter.export(set, languages: exportLanguages(languages), original: original, fallback: fallback,
                                      videoName: exportVideoName, to: folder)
    }

    /// 영상에 넣을 자막 트랙(지금 자막셋). `fallback`이면 빈 칸을 작품 원어로 채운다.
    func exportTracks(languages: [Language], fallback: Bool) -> [VideoExport.Track] {
        flushDraft()
        guard let set = currentSet, let original = originalLanguage else { return [] }
        return VideoExport.tracks(for: set, languages: exportLanguages(languages), original: original,
                                  fallback: fallback)
    }

    /// 영상 내보내기의 입력. 원본을 읽을 수 있으면 원본(mkv여도 ffmpeg가 읽는다), 아니면 변환본.
    /// mp4로 내보낼 때 원본이 mkv이고 변환본이 있으면 변환본을 쓴다(음성이 mp4에 넣을 수 있는 형식이다).
    func exportInputVideo(for container: SubtitleContainer) -> URL? {
        if container == .mp4, let videoURL, Self.isMKV(videoURL), let mediaURL, mediaURL != videoURL {
            return mediaURL
        }
        if let videoURL, FileManager.default.isReadableFile(atPath: videoURL.path) { return videoURL }
        return mediaURL
    }

    // MARK: 재생

    func seek(ms: Int) {
        let clamped = max(0, ms)
        playheadMs = clamped
        player.seek(to: CMTime(value: CMTimeValue(clamped), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// ←/→: 재생 위치를 `deltaMs`만큼 옮긴다(영상 처음과 끝 사이로). 재생 중이면 계속 재생한다.
    func seek(byMs deltaMs: Int) {
        guard player.currentItem != nil else { return }
        let end = durationMs > 0 ? durationMs : Int.max
        seek(ms: min(max(0, playheadMs + deltaMs), end))
    }

    /// ,/.: 한 프레임 앞뒤로 옮긴다. 재생을 멈추고 프레임 경계에 맞춘다(fps를 모르면 30fps로 본다).
    func stepFrame(_ count: Int) {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        let fps = videoInfo.map(\.fps).flatMap { $0 > 0 ? $0 : nil } ?? 30
        let frameMs = 1000 / fps
        // 지금 프레임 번호(경계에 걸친 반올림 오차는 그 프레임으로 본다) → 옮길 프레임의 시작 시각.
        let current = (Double(playheadMs) / frameMs + 0.001).rounded(.down)
        let target = max(0, current + Double(count))
        // 프레임 시작 시각을 ms로 올림해 앞 프레임이 보이지 않게 한다.
        var ms = Int((target * frameMs).rounded(.up))
        if durationMs > 0 { ms = min(ms, durationMs) }
        seek(ms: ms)
    }

    /// 재생 속도를 바꾼다. 재생 중이면 바로 그 속도로 이어 간다.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
    }

    /// Shift+,/Shift+.: 재생 속도를 한 단계 내리거나 올린다(1×–3×, 끝에서 멈춘다).
    func stepPlaybackRate(_ delta: Int) {
        let rates = Self.playbackRates
        let index = rates.firstIndex(of: playbackRate) ?? 0
        setPlaybackRate(rates[min(max(0, index + delta), rates.count - 1)])
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if let duration = project?.state.videoDurationMs, playheadMs >= duration - 50 { seek(ms: 0) }
            player.defaultRate = playbackRate
            player.play()
            isPlaying = true
        }
    }

    // MARK: MKV 변환

    /// MKV를 변환하는 중이다.
    var isConverting: Bool { conversionTask != nil }

    /// 진행 중인 MKV 변환을 취소한다(변환 시트의 "취소").
    func cancelConversion() {
        conversionTask?.cancel()
    }

    /// 변환을 취소하고, ffmpeg가 끝나 만들다 만 `video.mp4`를 지우고 열던 프로젝트를 정리할 때까지 기다린다.
    /// 앱을 끝낼 때 쓴다(그대로 끝내면 ffmpeg가 남아 나중에 변환본을 망친다).
    func cancelConversionAndWait() async {
        guard conversionTask != nil else { return }
        conversionTask?.cancel()
        // `convertMKV`가 끝나며 `conversionTask`를 비우고, 같은 흐름에서 `open`이 정리를 마친다.
        while conversionTask != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// `source` mkv를 `folder/video.mp4`로 바꾸고 그 길이(ms)를 돌려준다.
    /// `-c copy` 리먹스가 실패하거나 결과를 재생할 수 없으면 음성만 AAC로 다시 만든다.
    /// 그래도 안 되면 `AppError.mkvConversionFailed`, 취소하면 `CancellationError`. 실패하면 결과 파일을 지운다.
    private func convertMKV(_ source: URL, into folder: URL) async throws -> Int {
        guard let runner = FFmpegRunner.bundled() else { throw AppError.mkvConversionFailed }
        let output = folder.appendingPathComponent(Self.convertedVideoName)
        conversionProgress = 0
        let work = Task { () async throws -> Int in
            // 길이는 진행률에, 영상 코덱은 mp4 태그(HEVC → hvc1)에 쓴다. 못 읽어도 변환은 해 본다.
            let info = FFmpegProbe.parse(stderr: (try? await runner.probe(input: source)) ?? "")
            let durationMs = info.durationMs ?? 0
            let videoTag = FFmpegCommand.mp4VideoTag(forCodec: info.videoCodec)
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    // 변환이 끝난 뒤 늦게 온 진행률로 시트가 다시 뜨지 않게 한다.
                    guard let current = self.conversionProgress, fraction > current else { return }
                    self.conversionProgress = fraction
                }
            }
            do {
                for arguments in [FFmpegCommand.remux(input: source, output: output, videoTag: videoTag),
                                  FFmpegCommand.remuxWithAACAudio(input: source, output: output, videoTag: videoTag)] {
                    try Task.checkCancellation()
                    self.conversionProgress = 0
                    do {
                        try await runner.run(arguments, durationMs: durationMs, onProgress: report)
                    } catch FFmpegError.cancelled {
                        throw CancellationError()
                    } catch {
                        continue
                    }
                    if let ms = try? await Self.loadDurationMs(output) { return ms }
                }
                try Task.checkCancellation()
                throw AppError.mkvConversionFailed
            } catch {
                // ffmpeg는 이미 끝났다(`FFmpegRunner.run`이 종료를 기다린다). 만들다 만 결과를 지운다.
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        conversionTask = work
        defer {
            conversionTask = nil
            conversionProgress = nil
        }
        return try await work.value
    }

    // MARK: 오류

    func report(_ error: Error) {
        alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// 동작을 실행하고 오류는 경고로 띄운다.
    func perform(_ op: @MainActor () async throws -> Void) async {
        do { try await op() } catch { report(error) }
    }

    // MARK: 내부

    /// 키 창의 글 입력 실행 취소 기록(글 칸들이 같이 쓰는 창의 실행 취소 관리자)을 지운다.
    /// 자막 편집의 실행 취소는 편집기가 따로 가지니 영향이 없다.
    private static func clearTextUndo() {
        NSApp.keyWindow?.firstResponder?.undoManager?.removeAllActions()
    }

    private func installObservers() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.playheadMs = Int((time.seconds * 1000).rounded())
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    /// 다시 지정(`allowMKV == false`)은 mp4/mov만 받는다. 변환본이 없는 mkv 프로젝트는 mp4/mov로만 다시 지정한다.
    private static func checkVideoType(_ url: URL, allowMKV: Bool) throws {
        if isMKV(url) {
            if allowMKV { return }
            throw AppError.unsupportedRelinkVideo
        }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              type.conforms(to: .mpeg4Movie) || type.conforms(to: .quickTimeMovie)
        else { throw allowMKV ? AppError.unsupportedVideo : AppError.unsupportedRelinkVideo }
    }

    private static func isMKV(_ url: URL) -> Bool { url.pathExtension.lowercased() == "mkv" }

    /// 프로젝트 폴더에 있는 변환본. 없으면 nil.
    nonisolated private static func convertedURL(of p: Project) -> URL? {
        guard let name = p.state.convertedVideoName else { return nil }
        let url = p.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 영상 트랙의 해상도와 fps를 비동기로 읽는다. 다 읽기 전에 다른 영상을 열었으면 버린다.
    private func loadVideoInfo(_ media: URL) {
        videoInfo = nil
        Task {
            let info = await Self.readVideoInfo(media)
            guard mediaURL == media else { return }
            videoInfo = info
        }
    }

    private nonisolated static func readVideoInfo(_ url: URL) async -> VideoInfo? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return VideoInfo(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
                         fps: Double(fps))
    }

    /// 재생할 수 있고 길이가 유효한(0보다 긴 유한한) 영상만 받는다. 아니면 `AppError.unplayableVideo`.
    private static func loadDurationMs(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let (duration, isPlayable) = try? await asset.load(.duration, .isPlayable),
              isPlayable, duration.isValid, duration.isNumeric, !duration.isIndefinite
        else { throw AppError.unplayableVideo }
        let ms = Int((duration.seconds * 1000).rounded())
        guard ms > 0 else { throw AppError.unplayableVideo }
        return ms
    }
}

/// 인스펙터 탭: "조각" / "자막셋" / "작품 노트".
enum InspectorTab: Sendable {
    case clip, set, notes
}

/// 타임라인 도구: 선택(조각 선택·끌기) / 구간(레인 위 드래그로 구간 선택).
enum TimelineTool: Sendable {
    case select, range
}

extension AppModel {
    /// 제목 막대 "작품 노트": 노트 탭이면 조각 탭으로, 아니면 노트 탭으로.
    /// 인스펙터가 접혀 있으면 펴고 노트 탭을 연다.
    func toggleNotesTab() {
        if inspectorCollapsed {
            inspectorCollapsed = false
            inspectorTab = .notes
            return
        }
        inspectorTab = inspectorTab == .notes ? .clip : .notes
    }

    /// 조각 인스펙터를 보이게 한다(접혀 있으면 펴고 조각 탭으로). 본문 포커스를 요청하기 전에 부른다.
    func showClipInspector() {
        inspectorTab = .clip
        inspectorCollapsed = false
    }
}

/// 영상 트랙의 해상도와 fps.
struct VideoInfo: Equatable, Sendable {
    let width: Int
    let height: Int
    let fps: Double

    /// 예: "1920×1080 · 23.976fps". fps는 소수 셋째 자리까지, 끝의 0은 뺀다.
    var label: String {
        var parts: [String] = []
        if width > 0, height > 0 { parts.append("\(width)×\(height)") }
        if fps > 0 { parts.append("\(Self.fpsText(fps))fps") }
        return parts.joined(separator: " · ")
    }

    static func fpsText(_ fps: Double) -> String {
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
