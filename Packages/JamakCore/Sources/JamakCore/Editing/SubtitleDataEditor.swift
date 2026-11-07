import Foundation
import Observation

/// 프로젝트 자막 데이터 전체(모든 자막셋)와 검토 티켓을 되돌리기 가능하게 편집하는 모델(설계 11.5).
/// 공개 변경 메서드 한 번이 undo 한 단계이고, 데이터와 티켓을 함께 되돌린다.
/// 바뀌는 것이 없는 호출(없는 id, 같은 값 등)은 아무것도 하지 않고 undo도 남기지 않는다.
@MainActor @Observable
public final class SubtitleDataEditor {
    public private(set) var data: SubtitleData
    public private(set) var tickets: TicketBook
    public let undoManager: UndoManager
    /// 작품 원어. 이 칸의 문장이 바뀌면 그 조각의 검토됨이 모두 풀린다(번역 칸은 그 칸만). 원어를 바꾸면 따라 바뀐다.
    public private(set) var original: Language?

    /// 상태마다 고유한 버전. 새 편집은 새 버전을 받고, undo/redo는 이전/다음 버전을 복원한다.
    private var version: UUID
    private var savedVersion: UUID

    public var isDirty: Bool { version != savedVersion }

    /// 지금 상태의 버전. 데이터나 티켓이 바뀌면 달라지고, undo/redo하면 그 상태의 값으로 돌아간다.
    /// 보기 캐시의 무효화 키로 쓴다.
    public var revision: UUID { version }

    /// 되돌리기 단계 상한. 큰 자막 데이터를 오래 고쳐도 메모리가 끝없이 늘지 않게 한다.
    public static let undoLevels = 200

    public init(data: SubtitleData, tickets: TicketBook = TicketBook(), original: Language? = nil,
                undoManager: UndoManager = UndoManager()) {
        self.data = data
        self.original = original
        var ordered = tickets
        for set in data.sets { ordered.order(in: set) }
        self.tickets = ordered
        self.undoManager = undoManager
        let initial = UUID()
        self.version = initial
        self.savedVersion = initial
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = Self.undoLevels
    }

    public func markSaved() {
        savedVersion = version
    }

    /// 실행 취소·복귀 기록을 모두 지운다. 데이터, 티켓, 저장 상태(`isDirty`)는 그대로다.
    /// 자동 생성 결과를 저장한 뒤 부른다(생성 단계가 실행 취소로 진행 기록과 어긋나지 않게).
    public func clearHistory() {
        undoManager.removeAllActions()
    }

    public func set(_ id: UUID) -> CueSet? { data.set(id: id) }

    // MARK: - 조각

    /// 타임라인 순서 자리에 넣는다. 자막셋이 없거나 같은 id의 조각이 이미 있으면 아무것도 하지 않는다.
    public func addCue(_ cue: Cue, to set: UUID) {
        editSet(set, actionName: "조각 추가") { s, _ in
            guard !s.cues.contains(where: { $0.id == cue.id }) else { return }
            let at = s.cues.firstIndex { Cue.timelineOrder(cue, $0) } ?? s.cues.endIndex
            s.cues.insert(cue, at: at)
        }
    }

    /// 조각을 지우고, 티켓에서 그 조각의 변경(모든 언어)을 뺀다.
    public func deleteCue(_ id: UUID, in set: UUID) {
        editSet(set, actionName: "조각 삭제") { s, tickets in
            guard let i = s.cues.firstIndex(where: { $0.id == id }) else { return }
            s.cues.remove(at: i)
            tickets.removeAll(set: set, cues: [id])
        }
    }

    /// 그 종류(트랙)의 조각을 모두, 티켓의 그 조각 변경과 함께 한 단계로 지운다. 지운 조각 수를 돌려준다.
    @discardableResult
    public func deleteCues(ofKind kind: SubtitleKind, in set: UUID) -> Int {
        var removed = 0
        editSet(set, actionName: "트랙 비우기") { s, tickets in
            let ids = Set(s.cues.filter { $0.kind == kind }.map(\.id))
            guard !ids.isEmpty else { return }
            removed = ids.count
            s.cues.removeAll { ids.contains($0.id) }
            tickets.removeAll(set: set, cues: ids)
        }
        return removed
    }

    /// 같은 id 조각의 시간과 종류를 `cue`의 것으로 바꾼다. 문장은 그대로 둔다(`cue.texts`는 보지 않는다).
    /// 저장 순서도 타임라인 순서로 지킨다(조각을 빼서 제자리에 다시 넣는다). 그래야 뒤의 다른 편집이 순서를 몰래
    /// 바꾸며 상관없는 실행 취소 단계에 섞이지 않는다.
    public func updateTiming(_ cue: Cue, in set: UUID, actionName: String) {
        editSet(set, actionName: actionName) { s, _ in
            guard let i = s.cues.firstIndex(where: { $0.id == cue.id }) else { return }
            var moved = s.cues.remove(at: i)
            moved.start = cue.start
            moved.end = cue.end
            moved.kind = cue.kind
            let at = s.cues.firstIndex { Cue.timelineOrder(moved, $0) } ?? s.cues.endIndex
            s.cues.insert(moved, at: at)
        }
    }

    /// 한 칸의 문장을 바꾼다(사람이 고침). 빈 문장은 칸을 비운다. 문장이 바뀌면 그 칸이 든 티켓을 지운다.
    /// 자막셋이 없거나 자막셋에 없는 언어면 아무것도 하지 않고 false를 돌려준다.
    @discardableResult
    public func setText(_ text: String, cue: UUID, language: Language, in set: UUID, actionName: String) -> Bool {
        guard hasLanguage(language, in: set) else { return false }
        editSet(set, actionName: actionName) { s, tickets in
            guard let i = s.cues.firstIndex(where: { $0.id == cue }) else { return }
            let old = s.cues[i]
            s.cues[i].setText(text, for: language)
            if s.cues[i] != old { tickets.close(set: set, cells: [TicketBook.Cell(cue: cue, language: language)]) }
        }
        return true
    }

    /// `CueSet.replaceCues`를 한 단계로 한다. `adding`에 있는 id는 지우지 않고 고친다.
    /// 정말 지운 조각의 변경을 티켓에서 빼고, 문장이 바뀐 칸이 든 티켓은 지운다.
    /// 자막셋이 없거나 자막셋에 없는 언어면 아무것도 하지 않고 false를 돌려준다.
    @discardableResult
    public func replaceCues(in set: UUID, removing: Set<UUID>, adding: [SubtitleClip],
                            language: Language, actionName: String) -> Bool {
        guard hasLanguage(language, in: set) else { return false }
        editSet(set, actionName: actionName) { s, tickets in
            let old = s
            let removed = removing.subtracting(adding.map(\.id)).intersection(s.cues.map(\.id))
            s.replaceCues(removing: removing, adding: adding, language: language)
            tickets.removeAll(set: set, cues: removed)
            tickets.close(set: set, cells: Self.changedCells(from: old, to: s))
        }
        return true
    }

    /// 그 언어 칸들의 문장을 바꾼다. 문장이 바뀐 칸이 든 티켓은 지운다. 한 단계.
    /// 자막셋이 없거나 자막셋에 없는 언어면 아무것도 하지 않고 false를 돌려준다.
    @discardableResult
    public func applyTexts(_ texts: [UUID: String], language: Language, in set: UUID, actionName: String) -> Bool {
        guard hasLanguage(language, in: set) else { return false }
        editSet(set, actionName: actionName) { s, tickets in
            let old = s
            s.applyTexts(texts, language: language)
            tickets.close(set: set, cells: Self.changedCells(from: old, to: s))
        }
        return true
    }

    /// AI 결과(`CueWrite`)를 한 단계로 되쓴다: 없는 언어 더하기, 조각 지우기·더하기, 문장 바꾸기, 티켓 열기를 함께.
    /// 지운 조각의 변경은 티켓에서 빼고, 문장이 바뀐 칸(그 언어 칸과 옮겨 쓴 칸)이 든 티켓은 지운다.
    /// `write.clearsLanguageTickets`면 그 언어의 열린 티켓을 모두 지운다. `write.retranslated` 조각의 그 언어
    /// 원문 변경 티켓은 문장이 그대로여도 지운다. 그다음
    /// `write.tickets` 중 이 자막셋의 것을 `open`과 같은 규칙으로 연다.
    /// 자막셋이 없으면 아무것도 하지 않고 false.
    @discardableResult
    public func apply(_ write: CueWrite, to set: UUID, actionName: String) -> Bool {
        guard data.set(id: set) != nil else { return false }
        editSet(set, actionName: actionName) { s, tickets in
            let old = s
            s.apply(write)
            let removed = Set(old.cues.map(\.id)).subtracting(s.cues.map(\.id))
            tickets.removeAll(set: set, cues: removed)
            tickets.close(set: set, cells: Self.changedCells(from: old, to: s))
            if write.clearsLanguageTickets { tickets.removeAll(set: set, language: write.language) }
            if !write.retranslated.isEmpty {
                tickets.tickets.removeAll { ticket in
                    ticket.setID == set && ticket.language == write.language
                        && (ticket.reason == Ticket.sourceChangedReason
                            || ticket.changes.allSatisfy { $0.after.isEmpty })
                        && ticket.changes.contains { write.retranslated.contains($0.cueID) }
                }
            }
            for ticket in write.tickets where ticket.setID == set { _ = Self.admit(ticket, into: &s, book: &tickets) }
        }
        return true
    }

    /// 두 상태 모두에 있는 조각 중 문장이 바뀐 칸.
    private static func changedCells(from old: CueSet, to new: CueSet) -> Set<TicketBook.Cell> {
        let before = Dictionary(old.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = Set<TicketBook.Cell>()
        for cue in new.cues {
            guard let prior = before[cue.id], prior.texts != cue.texts else { continue }
            for language in Set(prior.texts.keys).union(cue.texts.keys) where prior.text(language) != cue.text(language) {
                out.insert(TicketBook.Cell(cue: cue.id, language: language))
            }
        }
        return out
    }

    private func hasLanguage(_ language: Language, in set: UUID) -> Bool {
        data.set(id: set)?.languages.contains(language) == true
    }

    /// 앞 조각의 끝을 뒤 조각의 시작에 맞춘다(`CueSet.snapEarlierEndToLaterStart`).
    public func fixOverlap(_ o: Overlap, in set: UUID) {
        editSet(set, actionName: "싱크 맞추기") { s, _ in s.snapEarlierEndToLaterStart(o) }
    }

    // MARK: - 자막셋·언어

    /// `like` 자막셋의 언어 설정을 따라 하는 빈 자막셋을 더하고 새 id를 돌려준다.
    /// `like`가 없으면 첫 자막셋을 따라 한다.
    @discardableResult
    public func addSet(name: String, like: UUID) -> UUID {
        var newID = UUID()
        edit(actionName: "자막셋 추가") { data, _ in
            guard let template = data.set(id: like) ?? data.sets.first else { return }
            newID = data.addSet(name: name, like: template)
        }
        return newID
    }

    /// 조각까지 복제한다(조각 id는 새로, 티켓은 복제하지 않는다). 없는 자막셋이면 `setMissing`.
    @discardableResult
    public func duplicateSet(_ id: UUID, name: String) throws -> UUID {
        var newID = UUID()
        try edit(actionName: "자막셋 복제") { data, _ in
            newID = try data.duplicateSet(id: id, name: name)
        }
        return newID
    }

    /// 자막셋과 그 티켓을 지운다. 마지막 하나면 `cannotDeleteLastSet`, 없으면 `setMissing`(undo 없음).
    public func deleteSet(_ id: UUID) throws {
        try edit(actionName: "자막셋 삭제") { data, tickets in
            try data.deleteSet(id: id)
            tickets.removeAll(set: id)
        }
    }

    /// 없는 자막셋이거나 이름이 같으면 아무것도 하지 않는다.
    public func renameSet(_ id: UUID, to name: String) {
        editSet(id, actionName: "자막셋 이름 바꾸기") { s, _ in s.name = name }
    }

    public func addLanguage(_ l: Language, to set: UUID) throws {
        try editSetThrowing(set, actionName: "언어 추가") { s, _ in try s.addLanguage(l) }
    }

    /// 언어 칸의 문장과 그 언어의 티켓을 함께 지운다. 작품 원어는 지울 수 없다.
    public func removeLanguage(_ l: Language, original: Language, from set: UUID) throws {
        try editSetThrowing(set, actionName: "언어 삭제") { s, tickets in
            try s.removeLanguage(l, original: original)
            tickets.removeAll(set: set, language: l)
        }
    }

    /// 작품 원어를 바꾸면서 자막셋 언어를 맞춘다(`SubtitleData.changeOriginalLanguage`). 한 단계.
    public func changeOriginalLanguage(from old: Language, to new: Language) throws {
        try edit(actionName: "작품 원어 바꾸기") { data, _ in try data.changeOriginalLanguage(from: old, to: new) }
    }

    /// 검토됨 정리에 쓰는 작품 원어를 바꾼다. 원어 변경이 저장된 뒤 앱이 부른다(실행 취소 대상이 아니다).
    public func setOriginal(_ language: Language?) {
        original = language
    }

    // MARK: - 주석·검토됨

    /// 조각의 주석을 바꾼다. 앞뒤 공백은 지운다. 검토됨은 그대로다. 한 단계(이름 "주석 고치기").
    public func setNote(_ note: String, cue: UUID, in set: UUID) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        editSet(set, actionName: "주석 고치기") { s, _ in
            guard let i = s.cues.firstIndex(where: { $0.id == cue }) else { return }
            s.cues[i].note = clean
        }
    }

    /// 조각들의 주석 끝에 줄을 바꿔 덧붙인다(주석이 없으면 그대로 쓴다). 빈 글이면 아무것도 하지 않는다. 한 단계.
    public func appendNote(_ note: String, cues: Set<UUID>, in set: UUID) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        editSet(set, actionName: "주석 고치기") { s, _ in
            for i in s.cues.indices where cues.contains(s.cues[i].id) {
                s.cues[i].note = s.cues[i].hasNote ? s.cues[i].note + "\n" + clean : clean
            }
        }
    }

    /// 칸의 검토됨을 켜거나 끈다. 자막셋에 없는 언어면 아무것도 하지 않는다. 한 단계.
    public func setReviewed(_ on: Bool, cue: UUID, language: Language, in set: UUID) {
        guard hasLanguage(language, in: set) else { return }
        editSet(set, actionName: on ? "검토됨 표시" : "검토됨 풀기") { s, _ in
            guard let i = s.cues.firstIndex(where: { $0.id == cue }) else { return }
            if on { s.cues[i].reviewed.insert(language) } else { s.cues[i].reviewed.remove(language) }
        }
    }

    // MARK: - 장면 메모

    /// 시작 순서 자리에 넣는다. 자막셋이 없거나 같은 id의 메모가 이미 있으면 아무것도 하지 않는다.
    public func addMemo(_ memo: SceneMemo, to set: UUID) {
        editSet(set, actionName: "메모 추가") { s, _ in
            guard !s.memos.contains(where: { $0.id == memo.id }) else { return }
            s.memos.append(memo)
            s.memos.sort(by: SceneMemo.order)
        }
    }

    /// 같은 id 메모의 시간과 글을 바꾸고 시작 순서를 지킨다.
    public func updateMemo(_ memo: SceneMemo, in set: UUID, actionName: String) {
        editSet(set, actionName: actionName) { s, _ in
            guard let i = s.memos.firstIndex(where: { $0.id == memo.id }) else { return }
            s.memos[i] = memo
            s.memos.sort(by: SceneMemo.order)
        }
    }

    public func deleteMemo(_ id: UUID, in set: UUID) {
        editSet(set, actionName: "메모 삭제") { s, _ in s.memos.removeAll { $0.id == id } }
    }

    /// 자막셋의 메모를 모두 한 단계로 지운다. 지운 수를 돌려준다.
    @discardableResult
    public func clearMemos(in set: UUID) -> Int {
        var removed = 0
        editSet(set, actionName: "메모 모두 지우기") { s, _ in
            removed = s.memos.count
            s.memos.removeAll()
        }
        return removed
    }

    // MARK: - 티켓

    /// 티켓을 열고 들인 티켓을 돌려준다. 한 단계(이름 `actionName`).
    /// - 이미 열린 티켓이 있는 칸(앞서 들인 티켓 포함), 없는 조각, 자막셋에 없는 언어, `after == before`인 변경은
    ///   그 변경만 뺀다. 한 티켓 안에서 같은 조각이 겹치면 먼저 나온 것을 쓴다. 남은 변경이 없으면 티켓을 버린다.
    /// - 변경은 타임라인 순서로 둔다. 고침이면 칸을 `after`로 바꾼다.
    @discardableResult
    public func open(_ new: [Ticket], actionName: String = "검토 티켓") -> [Ticket] {
        var opened: [Ticket] = []
        let original = original
        edit(actionName: actionName) { data, tickets in
            let old = data
            defer {
                for i in data.sets.indices {
                    if let prior = old.set(id: data.sets[i].id), prior != data.sets[i] {
                        Self.dropStaleReviews(in: &data.sets[i], from: prior, original: original)
                    }
                }
            }
            for ticket in new {
                guard let i = data.sets.firstIndex(where: { $0.id == ticket.setID }),
                      let admitted = Self.admit(ticket, into: &data.sets[i], book: &tickets) else { continue }
                opened.append(admitted)
            }
            for set in data.sets where opened.contains(where: { $0.setID == set.id }) { tickets.order(in: set) }
        }
        return opened
    }

    /// 반영: 의심이면 칸을 `after`로 바꾸고(`after`가 비었으면 그대로), 고침이면 그대로 둔다. 티켓을 지운다.
    /// 원문 티켓이고 칸의 최종 문장이 `before`와 다르면, 그 조각의 문장이 있는 다른 언어 칸마다 원문 변경 티켓
    /// (의심, 제안 없음)을 연다. 그 칸의 기존 티켓은 이것으로 바꾼다. 한 단계. 없는 티켓이면 아무것도 하지 않는다.
    /// 티켓의 칸들은 검토됨이 되고, `note`가 있으면 티켓의 조각마다 주석에 덧붙인다.
    public func apply(ticket id: UUID, note: String = "") {
        guard let ticket = tickets.tickets.first(where: { $0.id == id }) else { return }
        editSetMarking(ticket.setID, actionName: "티켓 반영") { s, tickets, marks in
            tickets.tickets.removeAll { $0.id == id }
            Self.resolve(ticket, note: note, in: &s, marks: &marks)
            if ticket.level == .suspect {
                Self.write(ticket.changes.filter { !$0.after.isEmpty }.map { ($0.cueID, $0.after) },
                           language: ticket.language, in: &s)
            }
            guard ticket.origin == .source else { return }
            let cues = Dictionary(s.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for change in ticket.changes {
                guard let cue = cues[change.cueID], cue.text(ticket.language) != change.before else { continue }
                for language in s.languages where language != ticket.language && !cue.text(language).isEmpty {
                    tickets.close(set: s.id, cells: [TicketBook.Cell(cue: cue.id, language: language)])
                    let retranslate = Ticket(
                        setID: s.id, origin: .translation, language: language, level: .suspect,
                        reason: Ticket.sourceChangedReason,
                        changes: [TicketChange(cueID: cue.id, before: cue.text(language), after: "")])
                    _ = Self.admit(retranslate, into: &s, book: &tickets)
                }
            }
        }
    }

    /// 미반영: 고침이면 칸을 `before`로 되돌리고, 의심이면 그대로 둔다. 티켓을 지운다. 한 단계.
    /// 없는 티켓이면 아무것도 하지 않는다. 티켓의 칸들은 검토됨이 되고, `note`가 있으면 조각마다 주석에 덧붙인다.
    public func reject(ticket id: UUID, note: String = "") {
        guard let ticket = tickets.tickets.first(where: { $0.id == id }) else { return }
        editSetMarking(ticket.setID, actionName: "티켓 미반영") { s, tickets, marks in
            tickets.tickets.removeAll { $0.id == id }
            Self.resolve(ticket, note: note, in: &s, marks: &marks)
            if ticket.level == .fix {
                Self.write(ticket.changes.map { ($0.cueID, $0.before) }, language: ticket.language, in: &s)
            }
        }
    }

    /// 티켓 하나를 자막셋 `s`에 들인다(`open`의 규칙). 들인 티켓을 돌려준다. 장부 순서는 호출자가 맞춘다.
    private static func admit(_ ticket: Ticket, into s: inout CueSet, book: inout TicketBook) -> Ticket? {
        guard ticket.setID == s.id, s.languages.contains(ticket.language) else { return nil }
        let position = Dictionary(s.cuesInTimelineOrder.enumerated().map { ($1.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var admitted = ticket
        admitted.changes = ticket.changes
            .filter { change in
                position[change.cueID] != nil && change.after != change.before
                    && !(ticket.level == .fix && change.after.isEmpty)   // 고침이 칸을 비우지 않게
                    && book.ticket(set: s.id, cue: change.cueID, language: ticket.language) == nil
                    && seen.insert(change.cueID).inserted
            }
            .sorted { position[$0.cueID]! < position[$1.cueID]! }
        guard !admitted.changes.isEmpty else { return nil }
        if admitted.level == .fix {
            write(admitted.changes.map { ($0.cueID, $0.after) }, language: admitted.language, in: &s)
        }
        book.tickets.append(admitted)
        return admitted
    }

    /// 사람이 처리한 티켓: 칸들을 검토됨으로 남기고(문장 정리 뒤에 붙는다), 주석을 덧붙인다.
    private static func resolve(_ ticket: Ticket, note: String, in s: inout CueSet, marks: inout Set<TicketBook.Cell>) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Set(ticket.cueIDs)
        for i in s.cues.indices where ids.contains(s.cues[i].id) {
            marks.insert(TicketBook.Cell(cue: s.cues[i].id, language: ticket.language))
            guard !clean.isEmpty else { continue }
            s.cues[i].note = s.cues[i].hasNote ? s.cues[i].note + "\n" + clean : clean
        }
    }

    private static func write(_ texts: [(UUID, String)], language: Language, in s: inout CueSet) {
        guard !texts.isEmpty else { return }
        s.applyTexts(Dictionary(texts, uniquingKeysWith: { first, _ in first }), language: language)
    }

    // MARK: - 단계

    /// 복사본을 고친 뒤 바뀐 것이 있을 때만 한 단계로 남긴다. 던지면 아무것도 바뀌지 않는다.
    private func edit(actionName: String,
                      _ body: (inout SubtitleData, inout TicketBook) throws -> Void) rethrows {
        var newData = data
        var newTickets = tickets
        try body(&newData, &newTickets)
        guard newData != data || newTickets != tickets else { return }
        commit(data: newData, tickets: newTickets, actionName: actionName)
    }

    /// 자막셋 하나를 고친다. 없는 자막셋이면 아무것도 하지 않는다. 바뀐 것이 있으면 그 자막셋 티켓을 첫 조각
    /// 시간 순서로 다시 둔다.
    private func editSet(_ id: UUID, actionName: String,
                         _ body: (inout CueSet, inout TicketBook) -> Void) {
        editSetMarking(id, actionName: actionName) { s, tickets, _ in body(&s, &tickets) }
    }

    /// `editSet`에 더해, 문장이 바뀐 칸의 검토됨을 풀고(`dropStaleReviews`) 그다음 `marks` 칸을 검토됨으로 한다.
    private func editSetMarking(_ id: UUID, actionName: String,
                                _ body: (inout CueSet, inout TicketBook, inout Set<TicketBook.Cell>) -> Void) {
        let original = original
        edit(actionName: actionName) { data, tickets in
            guard let i = data.sets.firstIndex(where: { $0.id == id }) else { return }
            let (oldSet, oldTickets) = (data.sets[i], tickets)
            var marks = Set<TicketBook.Cell>()
            body(&data.sets[i], &tickets, &marks)
            Self.dropStaleReviews(in: &data.sets[i], from: oldSet, original: original)
            if !marks.isEmpty {
                for j in data.sets[i].cues.indices {
                    for language in data.sets[i].languages
                    where marks.contains(TicketBook.Cell(cue: data.sets[i].cues[j].id, language: language)) {
                        data.sets[i].cues[j].reviewed.insert(language)
                    }
                }
            }
            if data.sets[i] != oldSet || tickets != oldTickets { tickets.order(in: data.sets[i]) }
        }
    }

    /// 두 상태 모두에 있는 조각에서 문장이 바뀐 칸의 검토됨을 푼다. 작품 원어 칸이 바뀌면 그 조각의 검토됨을 모두 푼다.
    /// 자막셋에 없는 언어의 검토됨도 지운다.
    static func dropStaleReviews(in set: inout CueSet, from old: CueSet, original: Language?) {
        let before = Dictionary(old.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let languages = Set(set.languages)
        for i in set.cues.indices {
            var cue = set.cues[i]
            guard !cue.reviewed.isEmpty else { continue }
            if let prior = before[cue.id], prior.texts != cue.texts {
                let changed = Set(prior.texts.keys).union(cue.texts.keys).filter { prior.text($0) != cue.text($0) }
                if let original, changed.contains(original) { cue.reviewed = [] } else { cue.reviewed.subtract(changed) }
            }
            cue.reviewed.formIntersection(languages)
            if cue.reviewed != set.cues[i].reviewed { set.cues[i].reviewed = cue.reviewed }
        }
    }

    /// 자막셋 하나를 고친다. 없는 자막셋이면 `setMissing`.
    private func editSetThrowing(_ id: UUID, actionName: String,
                                 _ body: (inout CueSet, inout TicketBook) throws -> Void) throws {
        try edit(actionName: actionName) { data, tickets in
            guard let i = data.sets.firstIndex(where: { $0.id == id }) else {
                throw SubtitleDataError.setMissing
            }
            try body(&data.sets[i], &tickets)
        }
    }

    private func commit(data newData: SubtitleData, tickets newTickets: TicketBook, actionName: String) {
        let old = Snapshot(data: data, tickets: tickets, version: version)
        undoManager.beginUndoGrouping()
        transition(from: old, to: Snapshot(data: newData, tickets: newTickets, version: UUID()))
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    private struct Snapshot {
        let data: SubtitleData
        let tickets: TicketBook
        let version: UUID
    }

    /// 상태를 바꾸고, 반대 방향 전환을 undo 스택(undo 중이면 redo 스택)에 등록한다.
    private func transition(from old: Snapshot, to new: Snapshot) {
        data = new.data
        tickets = new.tickets
        version = new.version
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.transition(from: new, to: old)
            }
        }
    }
}

extension SubtitleDataEditor {
    /// 두 상태 사이에 내용이나 티켓이 바뀐(더해지거나 지워진 것 포함) 자막셋 id. 실행 취소·복귀가 바꾼 자막셋으로
    /// 옮겨 가는 데 쓴다.
    public static func changedSets(from oldData: SubtitleData, _ oldTickets: TicketBook,
                                   to newData: SubtitleData, _ newTickets: TicketBook) -> Set<UUID> {
        var changed = Set<UUID>()
        if oldData != newData {
            let old = Dictionary(oldData.sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let new = Dictionary(newData.sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(old.keys).union(new.keys) where old[id] != new[id] { changed.insert(id) }
        }
        if oldTickets != newTickets {
            let old = Dictionary(oldTickets.tickets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let new = Dictionary(newTickets.tickets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(old.keys).union(new.keys) where old[id] != new[id] {
                if let setID = old[id]?.setID ?? new[id]?.setID { changed.insert(setID) }
            }
        }
        return changed
    }
}
