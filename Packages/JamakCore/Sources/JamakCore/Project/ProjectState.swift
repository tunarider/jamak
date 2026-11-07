import Foundation

/// 자막셋 하나의 한 대상 언어 번역 진행 상태(자막셋 전체 번역). 같은 선택일 때만 이어서 한다.
public struct TranslationProgress: Codable, Equatable, Sendable {
    public var sourceLanguage: String
    /// "빈 칸만 채우기". false면 그 언어 칸을 모두 다시 번역한다.
    public var fillEmptyOnly: Bool
    public var glossaryDone = false, translated = false
    /// 용어집과 번역을 모두 마쳤다.
    public var isComplete: Bool { glossaryDone && translated }

    public init(sourceLanguage: String, fillEmptyOnly: Bool = false) {
        self.sourceLanguage = sourceLanguage
        self.fillEmptyOnly = fillEmptyOnly
    }

    private enum CodingKeys: String, CodingKey { case sourceLanguage, fillEmptyOnly, glossaryDone, translated }

    /// 빠진 단계 키는 false로 읽는다(진행을 단계마다 나눠 저장한다).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try c.decode(String.self, forKey: .sourceLanguage)
        fillEmptyOnly = try c.decodeIfPresent(Bool.self, forKey: .fillEmptyOnly) ?? false
        glossaryDone = try c.decodeIfPresent(Bool.self, forKey: .glossaryDone) ?? false
        translated = try c.decodeIfPresent(Bool.self, forKey: .translated) ?? false
    }
}

/// project.json(형식 3). 자막은 subtitles.json에 따로 둔다.
public struct ProjectState: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public var version = ProjectState.currentVersion
    /// 사용자가 바꾼 프로젝트 이름. 없으면 폴더 이름(처음 만들 때의 영상 이름)을 쓴다.
    public var name: String?
    /// 작품 원어. 프로젝트 하나에 하나이고, 조각이 하나라도 생기면 바꿀 수 없다.
    public var originalLanguage: Language
    public var videoBookmark: Data
    public var videoPath: String
    public var videoFileSize: Int64
    public var videoDurationMs: Int
    public var convertedVideoName: String?
    /// 마지막으로 연 때. 목록의 최근순 정렬에 쓴다. 없으면 project.json 수정 시각을 쓴다.
    public var lastOpenedAt: Date?
    /// 마지막으로 연 자막셋. 없거나 지워졌으면 첫 자막셋을 연다.
    public var lastOpenedSetID: UUID?
    /// 자막셋별 출력 언어. 없으면 작품 원어.
    public var outputLanguages: [UUID: OutputLanguage]?
    /// 열린 검토 티켓.
    public var tickets: TicketBook?
    /// 자막셋별 자동 자막 생성 진행.
    public var setGeneration: [UUID: GenerationProgress]?
    /// 번역 진행. 키는 `translationKey(set:language:)`(`"<자막셋 id>/<언어>"`).
    public var setTranslations: [String: TranslationProgress]?
    /// LLM 작업별 토큰 사용량.
    public var tokenUsage: TokenUsageBook?

    public init(originalLanguage: Language, videoBookmark: Data, videoPath: String, videoFileSize: Int64, videoDurationMs: Int,
                convertedVideoName: String? = nil, lastOpenedAt: Date? = nil, lastOpenedSetID: UUID? = nil,
                outputLanguages: [UUID: OutputLanguage]? = nil, tickets: TicketBook? = nil,
                setGeneration: [UUID: GenerationProgress]? = nil,
                setTranslations: [String: TranslationProgress]? = nil,
                tokenUsage: TokenUsageBook? = nil, name: String? = nil) {
        self.name = name
        self.originalLanguage = originalLanguage
        self.videoBookmark = videoBookmark; self.videoPath = videoPath
        self.videoFileSize = videoFileSize; self.videoDurationMs = videoDurationMs
        self.convertedVideoName = convertedVideoName; self.lastOpenedAt = lastOpenedAt
        self.lastOpenedSetID = lastOpenedSetID; self.outputLanguages = outputLanguages
        self.tickets = tickets; self.setGeneration = setGeneration; self.setTranslations = setTranslations
        self.tokenUsage = tokenUsage
    }

    /// `setTranslations`의 키.
    public static func translationKey(set: UUID, language: Language) -> String {
        "\(set.uuidString)/\(language.rawValue)"
    }

    /// 자막셋 `set`의 자동 자막 생성 진행.
    public subscript(generation set: UUID) -> GenerationProgress? {
        get { setGeneration?[set] }
        set {
            var all = setGeneration ?? [:]
            all[set] = newValue
            setGeneration = all
        }
    }

    /// 모든 자막셋의 끝나지 않은 번역 진행(`translated`가 아직)의 용어집 단계를 다시 하게 한다.
    /// 노트(프로젝트에 하나)를 새로 써서 `## 번역: <언어>` 용어집이 지워졌을 때 부른다. 끝난 번역은 그대로 둔다.
    public mutating func resetUnfinishedGlossaries() {
        guard var all = setTranslations else { return }
        for (key, progress) in all where !progress.translated {
            all[key]?.glossaryDone = false
        }
        setTranslations = all
    }

    /// 자막셋 `set`의 번역 진행을 모두 지운다(조각을 모두 바꿔 예전 번역 진행이 맞지 않을 때).
    public mutating func clearTranslations(set: UUID) {
        let prefix = set.uuidString + "/"
        setTranslations = setTranslations?.filter { !$0.key.hasPrefix(prefix) }
    }

    /// 자막셋 `set`의 `language` 번역 진행.
    public subscript(translation set: UUID, language: Language) -> TranslationProgress? {
        get { setTranslations?[Self.translationKey(set: set, language: language)] }
        set {
            var all = setTranslations ?? [:]
            all[Self.translationKey(set: set, language: language)] = newValue
            setTranslations = all
        }
    }

    /// 지금 자막 데이터에 없는 것을 버린다: 지운 자막셋의 출력 언어·생성 진행·번역 진행(키가 자막셋 id가 아닌
    /// 번역 진행도), 그리고 티켓의 없는 자막셋·언어 티켓과 없는 조각 변경. 저장할 때 부른다(그래야 저장 전 실행 취소로
    /// 자막셋을 되돌려도 진행이 남는다). 목록 요약도 읽을 때 같은 것을 버린다.
    public mutating func prune(to data: SubtitleData) {
        let sets = Dictionary(data.sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        outputLanguages = outputLanguages?.filter { sets[$0.key] != nil }
        setGeneration = setGeneration?.filter { sets[$0.key] != nil }
        setTranslations = setTranslations?.filter { key, _ in
            guard let id = key.split(separator: "/").first.flatMap({ UUID(uuidString: String($0)) }) else { return false }
            return sets[id] != nil
        }
        if let book = tickets, !book.tickets.isEmpty {
            var cues: [UUID: Set<UUID>] = [:]
            for set in data.sets { cues[set.id] = Set(set.cues.map(\.id)) }
            let kept = book.tickets.compactMap { ticket -> Ticket? in
                guard let set = sets[ticket.setID], set.languages.contains(ticket.language) else { return nil }
                var kept = ticket
                kept.changes.removeAll { cues[ticket.setID]?.contains($0.cueID) != true }
                return kept.changes.isEmpty ? nil : kept
            }
            if kept != book.tickets { tickets = TicketBook(tickets: kept) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, originalLanguage, videoBookmark, videoPath, videoFileSize, videoDurationMs, convertedVideoName
        case lastOpenedAt, lastOpenedSetID, outputLanguages, tickets, setGeneration, setTranslations, tokenUsage
    }

    /// 자막셋 id 키 사전은 문자열 키로 쓴다. 읽을 때 id가 아닌 키, 모르는 출력 언어, 깨진 항목은 버린다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
        originalLanguage = try c.decode(Language.self, forKey: .originalLanguage)
        videoBookmark = try c.decode(Data.self, forKey: .videoBookmark)
        videoPath = try c.decode(String.self, forKey: .videoPath)
        videoFileSize = try c.decode(Int64.self, forKey: .videoFileSize)
        videoDurationMs = try c.decode(Int.self, forKey: .videoDurationMs)
        convertedVideoName = try c.decodeIfPresent(String.self, forKey: .convertedVideoName)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        lastOpenedSetID = try c.decodeIfPresent(UUID.self, forKey: .lastOpenedSetID)
        // 선택 블록은 너그럽게 읽는다. 깨진 항목은 버리고, 블록 모양이 틀리면 블록만 버린다.
        // 티켓 하나가 깨졌다고 자막이 멀쩡한 프로젝트가 목록에서 열 수 없게 되면 안 된다.
        if let raw = c.lossyDictionary(String.self, forKey: .outputLanguages) {
            outputLanguages = Self.byID(raw.compactMapValues(OutputLanguage.init(code:)))
        }
        tickets = try? c.decodeIfPresent(TicketBook.self, forKey: .tickets)
        if let raw = c.lossyDictionary(GenerationProgress.self, forKey: .setGeneration) {
            setGeneration = Self.byID(raw)
        }
        setTranslations = c.lossyDictionary(TranslationProgress.self, forKey: .setTranslations)
        tokenUsage = try? c.decodeIfPresent(TokenUsageBook.self, forKey: .tokenUsage)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(originalLanguage, forKey: .originalLanguage)
        try c.encode(videoBookmark, forKey: .videoBookmark)
        try c.encode(videoPath, forKey: .videoPath)
        try c.encode(videoFileSize, forKey: .videoFileSize)
        try c.encode(videoDurationMs, forKey: .videoDurationMs)
        try c.encodeIfPresent(convertedVideoName, forKey: .convertedVideoName)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encodeIfPresent(lastOpenedSetID, forKey: .lastOpenedSetID)
        try c.encodeIfPresent(outputLanguages.map { Self.byString($0.mapValues(\.code)) }, forKey: .outputLanguages)
        try c.encodeIfPresent(tickets, forKey: .tickets)
        try c.encodeIfPresent(setGeneration.map(Self.byString), forKey: .setGeneration)
        try c.encodeIfPresent(setTranslations, forKey: .setTranslations)
        try c.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
    }

    private static func byID<V>(_ raw: [String: V]) -> [UUID: V] {
        var out: [UUID: V] = [:]
        for (key, value) in raw { if let id = UUID(uuidString: key) { out[id] = value } }
        return out
    }

    private static func byString<V>(_ dict: [UUID: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
    }
}

public struct Project: Equatable, Sendable {
    public let folder: URL
    public var state: ProjectState
    public var subtitles: SubtitleData

    /// 보이는 이름: 사용자가 바꾼 이름, 없으면 폴더 이름.
    public var name: String { state.name ?? folder.lastPathComponent }

    public init(folder: URL, state: ProjectState, subtitles: SubtitleData) {
        self.folder = folder
        self.state = state
        self.subtitles = subtitles
    }
}

extension Project {
    /// 목록에 쓰는 요약. 지금 메모리에 있는 자막 데이터로 만든다.
    public var summary: ProjectSummary {
        ProjectSummary(folder: folder, state: state, subtitles: subtitles)
    }
}

/// 프로젝트 목록 한 줄. project.json과 subtitles.json으로 만든다.
/// 열 수 없는 폴더(`format`이 `.current`가 아님)는 `state`가 없다.
public struct ProjectSummary: Equatable, Sendable {
    public let folder: URL
    public var name: String
    /// 예전 형식이면 nil.
    public var state: ProjectState?
    /// 모든 자막셋 언어의 합집합, `Language.allCases` 순서.
    public var languages: [Language]
    public var setCount: Int
    /// 모든 자막셋의 조각 수 합계.
    public var cueCount: Int
    /// 모든 자막셋의 열린 티켓 수(고침·의심). 없는 자막셋·조각·언어의 티켓은 세지 않는다(`ProjectState.prune`).
    public var openTicketCount: Int
    public var format: Format
    public var isLegacy: Bool { format == .legacy }
    /// 열 수 있는 프로젝트다(형식 3, project.json을 읽었다).
    public var canOpen: Bool { format == .current }

    /// project.json의 형식.
    public enum Format: Equatable, Sendable {
        /// 형식 3. 열 수 있다.
        case current
        /// `version`이 없거나 3보다 작다. 열 수 없고 지울 수만 있다.
        case legacy
        /// `version`이 3보다 크다(새 버전 앱에서 만들었다). 열 수도 지울 수도 없다.
        case newer
        /// 형식 3인데 project.json을 읽을 수 없다. 열 수 없고, 확인을 거쳐 휴지통으로만 옮긴다.
        case corrupt
    }

    public init(folder: URL, name: String? = nil, state: ProjectState?, languages: [Language] = [],
                setCount: Int = 0, cueCount: Int = 0, openTicketCount: Int = 0, format: Format = .current) {
        self.folder = folder
        self.name = name ?? folder.lastPathComponent
        self.state = state
        self.languages = languages
        self.setCount = setCount
        self.cueCount = cueCount
        self.openTicketCount = openTicketCount
        self.format = format
    }

    /// 상태는 지금 있는 자막셋·조각·언어의 것만 남긴다(`ProjectState.prune`). 그래서 지운 자막셋의 멈춘 진행이
    /// "이어서 할 작업"이나 "<단계>에서 멈춤"으로 남지 않는다.
    public init(folder: URL, name: String? = nil, state: ProjectState, subtitles: SubtitleData) {
        let used = Set(subtitles.sets.flatMap(\.languages))
        var state = state
        state.prune(to: subtitles)
        self.init(folder: folder, name: name ?? state.name, state: state,
                  languages: Language.allCases.filter(used.contains),
                  setCount: subtitles.sets.count,
                  cueCount: subtitles.sets.reduce(0) { $0 + $1.cues.count },
                  openTicketCount: state.tickets?.tickets.count ?? 0)
    }

    /// 예전 형식 폴더. 이름은 폴더 이름이다.
    public static func legacy(folder: URL) -> ProjectSummary { unopenable(folder: folder, format: .legacy) }

    /// 열 수 없는 폴더(예전 형식, 새 형식, 깨진 project.json). 상태가 없고 이름은 폴더 이름이다.
    public static func unopenable(folder: URL, format: Format) -> ProjectSummary {
        ProjectSummary(folder: folder, state: nil, format: format)
    }
}

public enum VideoResolution: Equatable, Sendable {
    /// `isStale`: 북마크가 낡았다. 호출자는 북마크를 새로 만들어 저장해야 한다.
    case ok(URL, isStale: Bool = false)
    case missing
}

public enum ProjectError: Error, Equatable {
    case durationMismatch(expected: Int, actual: Int)
    /// subtitles.json이 없거나 깨졌거나 불변식을 어긴다.
    case corruptProject(URL)
    /// 예전 형식(버전이 3보다 작다)이라 열 수 없다.
    case legacyFormat(URL)
    /// 새 버전 앱에서 만든 형식(버전이 3보다 크다)이라 열 수 없다.
    case newerFormat(URL)
    /// 형식 3인데 project.json을 읽을 수 없다.
    case corruptState(URL)
    /// 저장하려는 자막 데이터가 형식 불변식(`SubtitleData.isValid`)을 어겨 쓰지 않았다.
    case invalidSubtitles(URL)
    /// 프로젝트 폴더가 프로젝트 루트 바로 아래에 있지 않아 지우지 않았다.
    case outsideRoot(URL)
}
