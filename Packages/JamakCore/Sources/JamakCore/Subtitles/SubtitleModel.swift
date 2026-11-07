import Foundation

/// 고정 언어. 한국어/일본어/영어만 쓴다.
public enum Language: String, Codable, CaseIterable, Sendable {
    case ko, ja, en

    public var displayName: String {
        switch self {
        case .ko: "한국어"
        case .ja: "일본어"
        case .en: "영어"
        }
    }
}

/// 조각. 시간, 종류, 언어별 문장, 검토됨 표시, 주석을 가진다. 없거나 빈 언어 = 빈 칸.
public struct Cue: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var start: Int
    public var end: Int
    public var kind: SubtitleKind
    public var texts: [Language: String]
    /// 사람이 검토를 마친 언어 칸. 전체·구간 검토는 이 칸을 대상에서 뺀다(문맥으로만 보낸다).
    /// 칸 문장이 바뀌면 풀린다(작품 원어 칸이 바뀌면 모든 칸이). 편집기가 지킨다.
    public var reviewed: Set<Language>
    /// 사람이 단 주석(확인한 사실). LLM 작업에 그 줄의 `note`로 간다. 내보내기에는 없다.
    public var note: String

    public init(id: UUID = UUID(), start: Int, end: Int, kind: SubtitleKind,
                texts: [Language: String] = [:], reviewed: Set<Language> = [], note: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
        self.texts = texts.filter { !$0.value.isEmpty }
        self.reviewed = reviewed
        self.note = note
    }

    /// 주석이 있다(공백만 있으면 없다).
    public var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func text(_ language: Language) -> String { texts[language] ?? "" }

    /// 시작, 끝, id 순(`TimelineOrder`).
    public static func timelineOrder(_ a: Cue, _ b: Cue) -> Bool {
        TimelineOrder.less(start: a.start, end: a.end, id: a.id, start: b.start, end: b.end, id: b.id)
    }

    /// 빈 문장은 칸을 지운다.
    public mutating func setText(_ text: String, for language: Language) {
        if text.isEmpty { texts[language] = nil } else { texts[language] = text }
    }

    private enum CodingKeys: String, CodingKey { case id, start, end, kind, texts, reviewed, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        kind = try c.decode(SubtitleKind.self, forKey: .kind)
        let raw = try c.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
        var out: [Language: String] = [:]
        for (key, value) in raw {
            if let language = Language(rawValue: key), !value.isEmpty { out[language] = value }
        }
        texts = out
        let marks = try c.decodeIfPresent([String].self, forKey: .reviewed) ?? []
        reviewed = Set(marks.compactMap(Language.init(rawValue:)))
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(kind, forKey: .kind)
        var raw: [String: String] = [:]
        for (language, value) in texts where !value.isEmpty { raw[language.rawValue] = value }
        try c.encode(raw, forKey: .texts)
        if !reviewed.isEmpty { try c.encode(reviewed.map(\.rawValue).sorted(), forKey: .reviewed) }
        if !note.isEmpty { try c.encode(note, forKey: .note) }
    }
}

/// 자막셋. 언어 1~3개와 조각을 가진다.
public struct CueSet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var languages: [Language]
    public var cues: [Cue]
    /// 장면 메모. 시작 순서로 저장한다. 조각이 아니므로 조각 편집이 건드리지 않는다.
    public var memos: [SceneMemo]

    public init(id: UUID = UUID(), name: String, languages: [Language], cues: [Cue] = [],
                memos: [SceneMemo] = []) {
        self.id = id
        self.name = name
        self.languages = languages
        self.cues = cues
        self.memos = memos
    }

    public static func initial(language: Language) -> CueSet {
        CueSet(name: "기본", languages: [language])
    }
}

public struct SubtitleData: Codable, Equatable, Sendable {
    public var sets: [CueSet]

    public init(sets: [CueSet]) { self.sets = sets }
}

/// 출력 언어. 저장 값은 언어 코드("ko"/"ja"/"en") 또는 "all"이다.
public enum OutputLanguage: Hashable, Codable, Sendable {
    case one(Language)
    case all

    public var code: String {
        switch self {
        case .one(let language): language.rawValue
        case .all: "all"
        }
    }

    public init?(code: String) {
        if code == "all" { self = .all; return }
        guard let language = Language(rawValue: code) else { return nil }
        self = .one(language)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let code = try c.decode(String.self)
        guard let value = OutputLanguage(code: code) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "알 수 없는 출력 언어: \(code)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(code)
    }
}

public enum SubtitleDataError: Error, Equatable {
    case languageExists
    case languageMissing
    case cannotRemoveOriginalLanguage
    /// 조각이 하나라도 있으면 작품 원어를 바꿀 수 없다.
    case originalLanguageLocked
    case cannotDeleteLastSet
    case setMissing
}

/// 겹쳐 보기 한 줄.
public struct DisplayCue: Equatable, Sendable {
    public let cue: Cue
    public let language: Language
    public let text: String
    public let isFallback: Bool
}

extension CueSet {
    public mutating func addLanguage(_ language: Language) throws {
        guard !languages.contains(language) else { throw SubtitleDataError.languageExists }
        languages.append(language)
    }

    public mutating func removeLanguage(_ language: Language, original: Language) throws {
        guard languages.contains(language) else { throw SubtitleDataError.languageMissing }
        guard language != original else { throw SubtitleDataError.cannotRemoveOriginalLanguage }
        languages.removeAll { $0 == language }
        for i in cues.indices {
            cues[i].texts[language] = nil
            cues[i].reviewed.remove(language)
        }
    }

    /// 출력 언어가 비면 작품 원어로 대신 보인다.
    public func displayText(of cue: Cue, for language: Language,
                            original: Language) -> (text: String, isFallback: Bool) {
        let own = cue.text(language)
        if !own.isEmpty || language == original { return (own, false) }
        let fallback = cue.text(original)
        return fallback.isEmpty ? ("", false) : (fallback, true)
    }

    /// 시각 `ms`에 보이는 조각들. 화면→음성→소리, 같은 종류 안에서는 타임라인 순서.
    /// `.all`은 문장이 있는 언어마다 한 줄(작품 원어 먼저), `.one`은 한 줄(대체 포함).
    public func displayCues(at ms: Int, output: OutputLanguage, original: Language,
                            hidden: Set<SubtitleKind> = []) -> [DisplayCue] {
        let active = cues
            .filter { $0.start <= ms && ms < $0.end && !hidden.contains($0.kind) }
            .sorted { a, b in
                let ka = SubtitleKind.allCases.firstIndex(of: a.kind) ?? 0
                let kb = SubtitleKind.allCases.firstIndex(of: b.kind) ?? 0
                if ka != kb { return ka < kb }
                return SubtitleClip.timelineOrder(clip(a), clip(b))
            }
        var result: [DisplayCue] = []
        for cue in active {
            switch output {
            case .one(let language):
                let shown = displayText(of: cue, for: language, original: original)
                if !shown.text.isEmpty {
                    result.append(DisplayCue(cue: cue, language: language, text: shown.text,
                                             isFallback: shown.isFallback))
                }
            case .all:
                let ordered = [original] + languages.filter { $0 != original }
                for language in ordered {
                    let text = cue.text(language)
                    if !text.isEmpty {
                        result.append(DisplayCue(cue: cue, language: language, text: text, isFallback: false))
                    }
                }
            }
        }
        return result
    }

    private func clip(_ cue: Cue) -> SubtitleClip {
        SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind, text: "")
    }

    /// 실제로 쓸 출력 언어. 자막셋에 없는 언어(지운 언어를 기억한 값)는 작품 원어가 된다.
    public func resolvedOutput(_ output: OutputLanguage, original: Language) -> OutputLanguage {
        if case .one(let language) = output, !languages.contains(language) { return .one(original) }
        return output
    }

    /// 타임라인 조각 위 글자: 출력 언어의 보기(조각 id = Cue id)와 작품 원어로 대신 보인 조각.
    /// "전체"나 자막셋에 없는 언어는 작품 원어로 보인다(대체 없음).
    public func timelineView(output: OutputLanguage,
                             original: Language) -> (view: SubtitleSet, fallback: Set<UUID>) {
        guard case .one(let language) = output, language != original, languages.contains(language) else {
            return (view(language: original), [])
        }
        var fallback = Set<UUID>()
        let clips = cues.map { cue in
            let shown = displayText(of: cue, for: language, original: original)
            if shown.isFallback { fallback.insert(cue.id) }
            return SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind, text: shown.text)
        }
        return (SubtitleSet(language: language.rawValue, clips: clips), fallback)
    }

    /// 한 언어의 보기. 조각 id = Cue id, 빈 칸은 "". 저장된 순서 그대로.
    public func view(language: Language) -> SubtitleSet {
        SubtitleSet(language: language.rawValue, clips: cues.map {
            SubtitleClip(id: $0.id, start: $0.start, end: $0.end, kind: $0.kind, text: $0.text(language))
        })
    }

    /// 조각을 타임라인 순서로. 편집기는 저장 순서를 타임라인 순서로 지키니 보통 그대로 돌려준다(한 번 훑어 확인한다).
    /// 어긋난 예전 파일만 정렬한다.
    public var cuesInTimelineOrder: [Cue] {
        let ordered = zip(cues, cues.dropFirst()).allSatisfy { !Cue.timelineOrder($1, $0) }
        return ordered ? cues : cues.sorted(by: Cue.timelineOrder)
    }

    /// 그 언어 칸만 바꾼다. 없는 id는 무시한다.
    public mutating func applyTexts(_ texts: [UUID: String], language: Language) {
        for i in cues.indices {
            if let text = texts[cues[i].id] { cues[i].setText(text, for: language) }
        }
    }

    /// `removing` 조각은 모든 언어째로 지우고, `adding`은 그 언어 칸만 채운 새 조각으로 더한다.
    /// `adding`의 id가 이미 있으면 새로 더하지 않고 그 조각의 시간·종류와 그 언어 칸만 바꾼다(id는 겹치지 않는다).
    /// `removing`과 `adding`에 함께 있는 id는 지우지 않고 고친다(다른 언어 칸은 남는다).
    /// 끝나면 조각을 타임라인 순서(시작, 끝, id)로 둔다.
    public mutating func replaceCues(removing: Set<UUID>, adding: [SubtitleClip], language: Language) {
        let removing = removing.subtracting(adding.map(\.id))
        cues.removeAll { removing.contains($0.id) }
        var index = Dictionary(cues.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for clip in adding {
            if let i = index[clip.id] {
                cues[i].start = clip.start
                cues[i].end = clip.end
                cues[i].kind = clip.kind
                cues[i].setText(clip.text, for: language)
            } else {
                index[clip.id] = cues.count
                cues.append(Cue(id: clip.id, start: clip.start, end: clip.end, kind: clip.kind,
                                texts: [language: clip.text]))
            }
        }
        cues.sort(by: Cue.timelineOrder)
    }
}

extension SubtitleData {
    public func set(id: UUID) -> CueSet? { sets.first { $0.id == id } }

    /// 저장 형식의 불변식: 자막셋 1개 이상, 자막셋마다 언어가 1개 이상이고 겹치지 않으며,
    /// 조각 id가 자막셋 안에서 겹치지 않는다.
    public var isValid: Bool {
        guard !sets.isEmpty else { return false }
        return sets.allSatisfy { set in
            !set.languages.isEmpty
                && Set(set.languages).count == set.languages.count
                && Set(set.cues.map(\.id)).count == set.cues.count
        }
    }

    /// `like`의 언어 설정을 따라 하는 빈 자막셋을 더하고 새 id를 돌려준다.
    @discardableResult
    public mutating func addSet(name: String, like: CueSet) -> UUID {
        let new = CueSet(name: name, languages: like.languages)
        sets.append(new)
        return new.id
    }

    /// 조각까지 복제한다(조각 id도 새로).
    @discardableResult
    public mutating func duplicateSet(id: UUID, name: String) throws -> UUID {
        guard let source = set(id: id) else { throw SubtitleDataError.setMissing }
        let copy = CueSet(name: name, languages: source.languages,
                      cues: source.cues.map {
                          Cue(start: $0.start, end: $0.end, kind: $0.kind, texts: $0.texts,
                              reviewed: $0.reviewed, note: $0.note)
                      },
                      memos: source.memos.map {
                          SceneMemo(start: $0.start, end: $0.end, text: $0.text)
                      })
        sets.append(copy)
        return copy.id
    }

    public mutating func deleteSet(id: UUID) throws {
        guard sets.contains(where: { $0.id == id }) else { throw SubtitleDataError.setMissing }
        guard sets.count > 1 else { throw SubtitleDataError.cannotDeleteLastSet }
        sets.removeAll { $0.id == id }
    }

    /// 작품 원어를 `old`에서 `new`로 바꾸면서 각 자막셋의 `languages`를 맞춘다. 조각이 하나라도 있으면
    /// `originalLanguageLocked`. `new`가 이미 있는 자막셋은 `old`만 뺀다. `old`가 없는 자막셋은 그대로 둔다.
    public mutating func changeOriginalLanguage(from old: Language, to new: Language) throws {
        guard old != new else { return }
        guard !sets.contains(where: { !$0.cues.isEmpty }) else { throw SubtitleDataError.originalLanguageLocked }
        for i in sets.indices {
            guard let at = sets[i].languages.firstIndex(of: old) else { continue }
            if sets[i].languages.contains(new) { sets[i].languages.remove(at: at) }
            else { sets[i].languages[at] = new }
        }
    }

    public mutating func renameSet(id: UUID, name: String) throws {
        guard let i = sets.firstIndex(where: { $0.id == id }) else { throw SubtitleDataError.setMissing }
        sets[i].name = name
    }
}
