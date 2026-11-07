import Foundation

/// AI 작업 결과를 자막셋의 한 언어 칸에 되쓰는 묶음(설계 8절, 11.1). `SubtitleDataEditor.apply`가 한 단계로 쓴다.
/// - 자막셋에 `language`가 없으면 먼저 더한다.
/// - `removing` 조각은 모든 언어째로 지우고(티켓의 그 조각 변경도 함께), `adding`은 그 언어 칸만 채운 새 조각으로 더한다.
/// - `texts`는 이미 있는 조각의 그 언어 칸만 바꾼다. 다른 언어 칸, 시간, 종류는 건드리지 않는다.
/// - `tickets`는 되쓴 뒤 `SubtitleDataEditor.open`과 같은 규칙으로 연다.
public struct CueWrite: Equatable, Sendable {
    public var language: Language
    public var removing: Set<UUID>
    public var adding: [SubtitleClip]
    public var texts: [UUID: String]
    public var tickets: [Ticket]
    /// 다른 언어 칸에 옮겨 쓸 문장(조각 id → 언어 → 문장). 구간 작업이 지운 조각의 번역을 결과 조각으로 옮긴다.
    /// `language` 칸과 자막셋에 없는 언어는 쓰지 않는다. 그 칸의 티켓도 `tickets`로 열 수 있다.
    public var carried: [UUID: [Language: String]]
    /// 되쓸 때 `language`의 열린 티켓을 모두 지운다(자막셋 전체 다시 번역).
    public var clearsLanguageTickets = false
    /// 다시 번역해 답을 받은 조각. 그 `language` 칸의 원문 변경 티켓(`Ticket.sourceChangedReason`)과 제안 없는
    /// 티켓은 문장이 그대로여도 지운다(다시 번역으로 답했다).
    public var retranslated: Set<UUID> = []
    /// 구간 작업이 지우는 조각의 주석을 옮겨 붙일 조각 → 주석(`RangeWrite`).
    public var notes: [UUID: String] = [:]

    public init(language: Language, removing: Set<UUID> = [], adding: [SubtitleClip] = [],
                texts: [UUID: String] = [:], tickets: [Ticket] = [], carried: [UUID: [Language: String]] = [:]) {
        self.language = language
        self.removing = removing
        self.adding = adding
        self.texts = texts
        self.tickets = tickets
        self.carried = carried
    }
}

extension CueSet {
    /// `write`를 되쓴다(티켓 말고). 없는 언어면 더한다.
    public mutating func apply(_ write: CueWrite) {
        if !languages.contains(write.language) { languages.append(write.language) }
        if !write.removing.isEmpty || !write.adding.isEmpty {
            replaceCues(removing: write.removing, adding: write.adding, language: write.language)
        }
        if !write.texts.isEmpty { applyTexts(write.texts, language: write.language) }
        if !write.carried.isEmpty {
            for i in cues.indices {
                guard let texts = write.carried[cues[i].id] else { continue }
                for (language, text) in texts where language != write.language && languages.contains(language) {
                    cues[i].setText(text, for: language)
                }
            }
        }
        if !write.notes.isEmpty {
            for i in cues.indices {
                guard let note = write.notes[cues[i].id], !note.isEmpty else { continue }
                cues[i].note = cues[i].hasNote ? cues[i].note + "\n" + note : note
            }
        }
    }
}

/// 구간 작업(구간·조각 다시 받아쓰기, 화면 글자 찾기)의 결과로 조각을 바꾸는 묶음.
/// 결과는 `language` 칸(작품 원어)만 가진다. 지우는 조각의 다른 언어 문장을 말없이 잃지 않는다:
/// - 같은 종류에서 결과 하나가 조각 하나를 바꾸면 그 조각 id를 그대로 쓴다(다른 언어 칸이 남는다).
/// - 아니면 지우는 조각마다 다른 언어 문장을 같은 종류 결과 중 가장 많이 겹치는 것(같으면 먼저 시작하는 것,
///   겹치는 것이 없으면 가장 가까운 것)으로 옮기고, 옮긴 칸마다 확인 티켓(의심, 제안 없음,
///   `Ticket.timingChangedReason`)을 연다.
///   여러 조각이 한 결과로 모이면 시간 순서로 줄을 바꿔 잇는다. 주석도 같은 결과로 옮긴다(확인 티켓은 없다).
/// - 같은 종류 결과가 하나도 없으면 옮길 곳이 없다. 호출자는 먼저 `losesOtherLanguages`로 보고 묻는다.
public enum RangeWrite {
    public static func replacing(_ targets: Set<UUID>, with results: [SubtitleClip], language: Language,
                                 in set: CueSet) -> CueWrite {
        let removed = set.cues.filter { targets.contains($0.id) }.sorted(by: Cue.timelineOrder)
        var adding = results
        var carried: [UUID: [Language: String]] = [:]
        var notes: [UUID: String] = [:]
        for kind in Set(removed.map(\.kind)) {
            let olds = removed.filter { $0.kind == kind }
            let slots = adding.indices.filter { adding[$0].kind == kind }
            guard !slots.isEmpty else { continue }
            if olds.count == 1, slots.count == 1 {
                let r = adding[slots[0]]
                adding[slots[0]] = SubtitleClip(id: olds[0].id, start: r.start, end: r.end, kind: r.kind, text: r.text)
                continue
            }
            for old in olds {
                let others = old.texts.filter { $0.key != language && !$0.value.isEmpty && set.languages.contains($0.key) }
                guard !others.isEmpty || old.hasNote,
                      let best = closest(to: old, among: slots.map { adding[$0] }) else { continue }
                if old.hasNote { notes[best.id] = notes[best.id].map { $0 + "\n" + old.note } ?? old.note }
                for (lang, text) in others {
                    carried[best.id, default: [:]][lang] = carried[best.id]?[lang].map { $0 + "\n" + text } ?? text
                }
            }
        }
        let tickets = adding.flatMap { clip in
            (carried[clip.id] ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }.map { lang, text in
                Ticket(setID: set.id, origin: .translation, language: lang, level: .suspect,
                       reason: Ticket.timingChangedReason,
                       changes: [TicketChange(cueID: clip.id, before: text, after: "")])
            }
        }
        var write = CueWrite(language: language, removing: targets, adding: adding, tickets: tickets, carried: carried)
        write.notes = notes
        return write
    }

    /// 가장 많이 겹치는 결과. 같으면 먼저 시작하는 것. 겹치는 것이 없으면 가장 가까운 것(같으면 먼저 시작하는 것).
    private static func closest(to cue: Cue, among clips: [SubtitleClip]) -> SubtitleClip? {
        func overlap(_ c: SubtitleClip) -> Int { min(c.end, cue.end) - max(c.start, cue.start) }
        func gap(_ c: SubtitleClip) -> Int { max(c.start - cue.end, cue.start - c.end, 0) }
        return clips.min { a, b in
            let (oa, ob) = (max(overlap(a), 0), max(overlap(b), 0))
            if oa != ob { return oa > ob }
            if oa == 0, gap(a) != gap(b) { return gap(a) < gap(b) }
            return SubtitleClip.timelineOrder(a, b)
        }
    }

    /// 지울 조각 중 다른 언어 문장이나 주석이 있는데, 같은 종류 결과가 없어 옮길 곳이 없는 것이 있다.
    public static func dropsCarried(_ targets: Set<UUID>, results: [SubtitleClip], in set: CueSet,
                                    original: Language) -> Bool {
        let kinds = Set(results.map(\.kind))
        return set.cues.contains { cue in
            targets.contains(cue.id) && !kinds.contains(cue.kind)
                && (cue.hasNote || cue.texts.contains { $0.key != original && !$0.value.isEmpty })
        }
    }

    /// 지울 조각 중 다른 언어 문장이나 주석이 있는 것이 있다(같은 종류 결과가 없으면 그것이 사라진다).
    public static func losesOtherLanguages(_ targets: Set<UUID>, in set: CueSet, original: Language) -> Bool {
        set.cues.contains { cue in
            targets.contains(cue.id) && (cue.hasNote || cue.texts.contains { $0.key != original && !$0.value.isEmpty })
        }
    }
}

/// 자동 자막 생성 단계(받아쓰기, 소리, 화면 글자)의 결과를 되쓸 묶음.
public enum GenerationWrite {
    /// 이미 있는 같은 결과를 다시 넣지 않는 방식(앞선 실행이 저장 중에 멈춘 경우).
    public enum Dedupe: Sendable {
        case none
        /// 겹치고 문장이 같은 소리 조각(`SoundEventMerger.droppingOverlaps`).
        case sounds
        /// 시간과 문장이 같은 화면 조각.
        case screenText
    }

    /// 생성 결과를 작품 원어(`original`) 칸에 쓰는 묶음. 새 조각의 다른 언어 칸은 비어 있다.
    /// - `replacingKinds`: 이 종류의 기존 조각을 모두 지운다(고른 트랙을 다시 만드는 첫 쓰기 단계). 다른 종류는
    ///   그대로 둔다. 지운 조각의 티켓은 편집기의 조각 삭제 규칙으로 함께 지워지고, 장면 메모는 그대로다.
    /// - `dedupe`대로 남는 조각(지우지 않는 종류)의 원어 칸에 이미 있는 같은 결과를 뺀다.
    public static func stage(_ generated: [SubtitleClip], original: Language, in set: CueSet,
                             replacingKinds: Set<SubtitleKind>, dedupe: Dedupe = .none) -> CueWrite {
        let removing = Set(set.cues.filter { replacingKinds.contains($0.kind) }.map(\.id))
        let base = dedupe == .none ? [] : set.view(language: original).clips.filter { !removing.contains($0.id) }
        var found = generated
        switch dedupe {
        case .none: break
        case .sounds: found = SoundEventMerger.droppingOverlaps(found, with: base)
        case .screenText:
            found = found.filter { clip in
                !base.contains { $0.kind == .screen && $0.start == clip.start && $0.end == clip.end && $0.text == clip.text }
            }
        }
        return CueWrite(language: original, removing: removing, adding: found)
    }
}

/// 번역 결과를 같은 조각의 대상 언어 칸에 되쓴다(설계 8절). 시간을 복사하거나 조각을 만들지 않는다.
/// 번역은 칸에 바로 쓰고 표시나 티켓을 만들지 않는다(검토는 따로 하는 작업이다).
public enum TranslationWrite {
    /// 번역할 원문 보기(조각 id = Cue id, 타임라인 순서): 원문 칸이 비지 않았고, `fillEmptyOnly`면 대상 칸이 빈 조각.
    /// `scope`가 있으면 그 조각만.
    public static func sources(in set: CueSet, source: Language, target: Language, scope: Set<UUID>?,
                               fillEmptyOnly: Bool) -> [SubtitleClip] {
        set.cuesInTimelineOrder
            .filter { cue in
                (scope?.contains(cue.id) ?? true) && !cue.text(source).isEmpty
                    && (!fillEmptyOnly || cue.text(target).isEmpty)
            }
            .map { SubtitleClip(id: $0.id, start: $0.start, end: $0.end, kind: $0.kind, text: $0.text(source)) }
    }

    /// 다시 번역(`fillEmptyOnly` 아님)으로 지워지는 대상 언어의 열린 티켓 수(시트 경고용).
    /// 자막셋 전체(`scope` nil)는 그 언어의 티켓을 모두 지우고, 고른 조각은 다시 번역할 조각에 걸린 그 언어 티켓을 센다.
    public static func ticketsCleared(in set: CueSet, tickets: TicketBook, source: Language, target: Language,
                                      scope: Set<UUID>?) -> Int {
        let own = tickets.tickets(set: set.id).filter { $0.language == target }
        guard let scope else { return own.count }
        // 이미 번역이 있어 다시 쓰는 조각.
        let ids = Set(sources(in: set, source: source, target: target, scope: scope, fillEmptyOnly: false).map(\.id))
            .subtracting(sources(in: set, source: source, target: target, scope: scope, fillEmptyOnly: true).map(\.id))
        return own.count { $0.changes.contains { ids.contains($0.cueID) } }
    }

    /// 번역 결과(조각 id → 문장)를 `target` 칸에 쓰는 묶음. `sources`에 있던 조각만 다룬다. 티켓은 열지 않는다.
    /// - 결과가 없는 조각은 칸을 그대로 둔다.
    /// - `fillEmptyOnly`면 그사이 채워진 칸은 그대로 둔다.
    /// - `clearsTickets`(자막셋 전체 다시 번역)면 되쓸 때 그 언어의 열린 티켓을 모두 지운다.
    /// - `fillEmptyOnly`가 아니면 결과가 있는 조각을 `retranslated`에 둔다(원문 변경 티켓을 닫는다).
    public static func write(_ texts: [UUID: String], sources: [SubtitleClip], in set: CueSet,
                             target: Language, fillEmptyOnly: Bool, clearsTickets: Bool = false) -> CueWrite {
        let cues = Dictionary(set.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var write = CueWrite(language: target)
        write.clearsLanguageTickets = clearsTickets
        for clip in sources {
            guard let cue = cues[clip.id], let new = texts[clip.id], !new.isEmpty else { continue }
            let old = cue.text(target)
            if fillEmptyOnly && !old.isEmpty { continue }
            if new != old { write.texts[clip.id] = new }
            if !fillEmptyOnly { write.retranslated.insert(clip.id) }
        }
        return write
    }
}
