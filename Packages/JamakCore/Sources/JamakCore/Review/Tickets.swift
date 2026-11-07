import Foundation

/// LLM이 한 언어 칸들(조각 1개 이상)에 낸 제안(설계 5절). 고침은 이미 칸에 넣었고, 의심은 넣지 않았다.
/// 사람이 반영하거나 미반영하면 지운다.
public struct Ticket: Codable, Equatable, Identifiable, Sendable {
    /// 원문 검토에서 났는지, 번역 검토에서 났는지.
    public enum Origin: String, Codable, Sendable { case source, translation }
    /// 고침(칸을 `after`로 바꿔 둠) / 의심(칸은 `before` 그대로).
    public enum Level: String, Codable, Sendable { case fix, suspect }

    /// 원문 티켓을 처리해 원문이 바뀐 조각의 번역 칸에 다는 티켓의 이유.
    public static let sourceChangedReason = "원문이 바뀌었어요. 다시 번역이 필요할 수 있어요"
    /// 구간 작업이 다른 언어 문장을 새 조각으로 옮긴 칸에 다는 티켓의 이유.
    public static let timingChangedReason = "시간이 바뀌어 다시 확인이 필요해요"

    public var id: UUID
    public var setID: UUID
    public var origin: Origin
    /// `changes`의 모든 칸이 이 언어다.
    public var language: Language
    public var level: Level
    public var reason: String
    /// 1개 이상, 타임라인 순서.
    public var changes: [TicketChange]

    public init(id: UUID = UUID(), setID: UUID, origin: Origin, language: Language, level: Level, reason: String,
                changes: [TicketChange]) {
        self.id = id; self.setID = setID; self.origin = origin; self.language = language
        self.level = level; self.reason = reason; self.changes = changes
    }

    public var cueIDs: [UUID] { changes.map(\.cueID) }
}

public struct TicketChange: Codable, Equatable, Sendable {
    public var cueID: UUID
    /// 티켓을 만들 때 그 칸의 문장.
    public var before: String
    /// 제안 문장. 빈 문자열이면 제안이 없다(확인·다시 번역 티켓).
    public var after: String
    /// 원문 칸 티켓: `before`·`after`를 사용자 언어로 옮긴 뜻(LLM이 검토 때 함께 낸다). 없으면 빈 문자열.
    public var meaningBefore: String
    public var meaningAfter: String

    public init(cueID: UUID, before: String, after: String, meaningBefore: String = "", meaningAfter: String = "") {
        self.cueID = cueID; self.before = before; self.after = after
        self.meaningBefore = meaningBefore; self.meaningAfter = meaningAfter
    }

    private enum CodingKeys: String, CodingKey { case cueID, before, after, meaningBefore, meaningAfter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cueID = try c.decode(UUID.self, forKey: .cueID)
        before = try c.decode(String.self, forKey: .before)
        after = try c.decode(String.self, forKey: .after)
        meaningBefore = try c.decodeIfPresent(String.self, forKey: .meaningBefore) ?? ""
        meaningAfter = try c.decodeIfPresent(String.self, forKey: .meaningAfter) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cueID, forKey: .cueID)
        try c.encode(before, forKey: .before)
        try c.encode(after, forKey: .after)
        if !meaningBefore.isEmpty { try c.encode(meaningBefore, forKey: .meaningBefore) }
        if !meaningAfter.isEmpty { try c.encode(meaningAfter, forKey: .meaningAfter) }
    }
}

/// 열린 티켓 장부. 칸(자막셋, 조각, 언어) 하나에 열린 티켓은 하나까지다. 편집기가 자막셋마다 첫 조각 시간 순서로
/// 둔다.
public struct TicketBook: Codable, Equatable, Sendable {
    public var tickets: [Ticket]

    public init(tickets: [Ticket] = []) { self.tickets = tickets }

    private enum CodingKeys: String, CodingKey { case tickets }

    /// 깨진 티켓(모르는 언어·종류, 빠진 필드)은 버리고 나머지를 읽는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tickets = try c.decode([Lossy<Ticket>].self, forKey: .tickets).compactMap(\.value)
            .filter { !$0.changes.isEmpty }
    }

    /// 그 칸에 열린 티켓.
    public func ticket(set: UUID, cue: UUID, language: Language) -> Ticket? {
        tickets.first { $0.setID == set && $0.language == language && $0.changes.contains { $0.cueID == cue } }
    }

    /// 자막셋의 티켓(첫 조각 시간 순서).
    public func tickets(set: UUID) -> [Ticket] { tickets.filter { $0.setID == set } }

    /// 티켓이 있는 조각. `level`이 nil이면 모든 단계, `language`가 nil이면 모든 언어.
    public func cueIDs(set: UUID, level: Ticket.Level?, language: Language? = nil) -> Set<UUID> {
        Set(tickets.filter {
            $0.setID == set && (level == nil || $0.level == level) && (language == nil || $0.language == language)
        }.flatMap(\.cueIDs))
    }

    /// `list`(첫 조각 시간 순서)에서 다음·이전 티켓. 끝에서 처음으로(처음에서 끝으로) 돈다. 비었으면 nil.
    /// - `id`가 `list`에 있으면 그 옆 티켓.
    /// - 아니면 조각 `cue`의 타임라인 자리(`order`)에서 첫 조각이 뒤(앞)에 있는 첫(마지막) 티켓.
    /// - 둘 다 없으면 처음(끝) 티켓.
    public static func neighbor(of id: UUID?, near cue: UUID?, in list: [Ticket], order: [UUID],
                                forward: Bool) -> Ticket? {
        guard !list.isEmpty else { return nil }
        if let id, let i = list.firstIndex(where: { $0.id == id }) {
            return list[forward ? (i + 1) % list.count : (i + list.count - 1) % list.count]
        }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        if let cue, let here = position[cue] {
            func first(_ t: Ticket) -> Int { t.changes.compactMap { position[$0.cueID] }.min() ?? Int.max }
            if forward { return list.first { first($0) > here } ?? list.first }
            return list.last { first($0) < here } ?? list.last
        }
        return forward ? list.first : list.last
    }

    /// 티켓 `id`를 처리한 뒤 고를 티켓: 처리 전 목록 `before`에서 그 뒤에 있던 티켓 중 처리 뒤 목록 `after`에
    /// 남은 첫 티켓, 없으면 그 앞에 있던 티켓 중 남은 마지막 티켓, 없으면 `after`의 처음 티켓.
    /// `id`가 `before`에 없었으면 nil(보이지 않던 티켓을 처리했으니 고른 것을 옮기지 않는다).
    public static func successor(of id: UUID, before: [Ticket], after: [Ticket]) -> Ticket? {
        guard let i = before.firstIndex(where: { $0.id == id }) else { return nil }
        let remaining = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let next = before[(i + 1)...].lazy.compactMap({ remaining[$0.id] }).first { return next }
        if let prior = before[..<i].reversed().lazy.compactMap({ remaining[$0.id] }).first { return prior }
        return after.first { $0.id != id }
    }

    /// 다음으로 티켓이 있는 조각(타임라인 순서). 끝에서 처음으로 돈다. 없으면 nil.
    public func next(after cue: UUID?, in set: CueSet) -> UUID? {
        let (order, marked) = ticketedOrder(in: set)
        guard !marked.isEmpty else { return nil }
        guard let cue, let idx = order.firstIndex(of: cue) else { return marked.first }
        return order[(idx + 1)...].first(where: marked.contains) ?? marked.first
    }

    /// 이전으로 티켓이 있는 조각(타임라인 순서). 처음에서 끝으로 돈다. 없으면 nil.
    public func previous(before cue: UUID?, in set: CueSet) -> UUID? {
        let (order, marked) = ticketedOrder(in: set)
        guard !marked.isEmpty else { return nil }
        guard let cue, let idx = order.firstIndex(of: cue) else { return marked.last }
        return order[..<idx].last(where: marked.contains) ?? marked.last
    }

    private func ticketedOrder(in set: CueSet) -> ([UUID], [UUID]) {
        let ids = cueIDs(set: set.id, level: nil)
        guard !ids.isEmpty else { return ([], []) }
        let order = set.cuesInTimelineOrder.map(\.id)
        return (order, order.filter(ids.contains))
    }

    /// 사라진 조각의 변경을 뺀다. 남은 변경이 없는 티켓은 지운다.
    public mutating func removeAll(set: UUID, cues: Set<UUID>) {
        guard !cues.isEmpty else { return }
        tickets = tickets.compactMap { ticket in
            guard ticket.setID == set, ticket.changes.contains(where: { cues.contains($0.cueID) }) else { return ticket }
            var trimmed = ticket
            trimmed.changes.removeAll { cues.contains($0.cueID) }
            return trimmed.changes.isEmpty ? nil : trimmed
        }
    }

    /// 언어 삭제.
    public mutating func removeAll(set: UUID, language: Language) {
        tickets.removeAll { $0.setID == set && $0.language == language }
    }

    /// 자막셋 삭제.
    public mutating func removeAll(set: UUID) { tickets.removeAll { $0.setID == set } }

    /// 그 칸이 든 티켓을 통째로 지운다(사람이 칸을 고쳤을 때).
    mutating func close(set: UUID, cells: Set<Cell>) {
        guard !cells.isEmpty else { return }
        tickets.removeAll { ticket in
            ticket.setID == set && ticket.changes.contains { cells.contains(Cell(cue: $0.cueID, language: ticket.language)) }
        }
    }

    /// 자막셋의 티켓을 첫 조각 시간 순서로 다시 둔다(다른 자막셋 티켓의 자리는 그대로).
    mutating func order(in set: CueSet) {
        let slots = tickets.indices.filter { tickets[$0].setID == set.id }
        guard slots.count > 1 else { return }
        let position = Dictionary(set.cuesInTimelineOrder.enumerated().map { ($1.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        func first(_ t: Ticket) -> Int { t.changes.compactMap { position[$0.cueID] }.min() ?? Int.max }
        let sorted = slots.map { tickets[$0] }.enumerated()
            .sorted { (first($0.element), $0.offset) < (first($1.element), $1.offset) }
            .map(\.element)
        for (slot, ticket) in zip(slots, sorted) { tickets[slot] = ticket }
    }

    /// 칸(조각, 언어).
    struct Cell: Hashable {
        let cue: UUID
        let language: Language
    }
}

/// 티켓 패널의 거르기(설계 7절): 언어(작품 원어면 원문 티켓, 다른 언어면 그 언어의 번역 티켓) × 단계.
/// nil은 전체다.
public struct TicketFilter: Equatable, Sendable {
    public var language: Language?
    public var level: Ticket.Level?

    public init(language: Language? = nil, level: Ticket.Level? = nil) {
        self.language = language; self.level = level
    }

    public func matches(_ ticket: Ticket) -> Bool {
        (language == nil || ticket.language == language) && (level == nil || ticket.level == level)
    }

    /// 자막셋에 없는 언어를 거르고 있으면(언어를 지웠거나 다른 자막셋) 언어는 전체로 푼다.
    public func resolved(languages: [Language]) -> TicketFilter {
        guard let language, !languages.contains(language) else { return self }
        return TicketFilter(language: nil, level: level)
    }
}
