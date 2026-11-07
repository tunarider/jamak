import Foundation
import JamakCore
import JamakMedia

/// 검토 티켓(고침·의심)과 작품 노트.
extension AppModel {
    // MARK: 검토 티켓

    /// 지금 자막셋의 열린 티켓(첫 조각 시간 순서).
    var openTickets: [Ticket] {
        guard let editor, let currentSetID else { return [] }
        return editor.tickets.tickets(set: currentSetID)
    }

    /// 지금 자막셋에 맞춘 거르기(자막셋에 없는 언어를 거르고 있으면 언어는 전체).
    var effectiveTicketFilter: TicketFilter {
        ticketFilter.resolved(languages: currentSet?.languages ?? [])
    }

    /// 티켓 패널에 보이는 티켓: 거른 열린 티켓.
    var visibleTickets: [Ticket] {
        let filter = effectiveTicketFilter
        return openTickets.filter(filter.matches)
    }

    /// 고른 티켓(지금 자막셋에 열려 있고 거르기에 보일 때).
    var selectedTicket: Ticket? {
        guard let selectedTicketID else { return nil }
        return visibleTickets.first { $0.id == selectedTicketID }
    }

    /// 티켓을 고른다: 첫 조각을 고르고(숨긴 레인이면 보이게) 재생 위치를 그 시작으로 옮긴다.
    func selectTicket(_ id: UUID) {
        guard let ticket = openTickets.first(where: { $0.id == id }) else { return }
        selectedTicketID = id
        guard let first = ticket.changes.first,
              let cue = currentSet?.cues.first(where: { $0.id == first.cueID }) else { return }
        reveal(kind: cue.kind)
        select(cue.id)
        seek(ms: cue.start)
    }

    /// 다음 티켓(보이는 티켓 중). 고른 티켓이 없으면 고른 조각 뒤의 첫 티켓. 끝에서 처음으로 돈다.
    func selectNextTicket() { stepTicket(forward: true) }

    /// 이전 티켓(보이는 티켓 중). 처음에서 끝으로 돈다.
    func selectPreviousTicket() { stepTicket(forward: false) }

    /// 티켓을 반영한다: 의심이면 제안 문장으로 바꾸고, 고침이면 그대로 둔다. 실행 취소 한 단계("티켓 반영").
    /// 티켓의 칸은 검토됨이 되고, 주석 칸에 쓴 글은 조각 주석에 덧붙는다. 고른 티켓이었으면 다음 티켓을 고른다.
    func applyTicket(_ id: UUID) {
        // 주석 칸 글은 지우지 않는다: 반영을 실행 취소해 티켓이 돌아오면 칸에 다시 보인다.
        process(id) { $0.apply(ticket: id, note: ticketNotes[id] ?? "") }
    }

    /// 티켓을 미반영한다: 고침이면 원래 문장으로 되돌리고, 의심이면 그대로 둔다. 실행 취소 한 단계("티켓 미반영").
    /// 티켓의 칸은 검토됨이 되고, 주석 칸에 쓴 글은 조각 주석에 덧붙는다. 고른 티켓이었으면 다음 티켓을 고른다.
    func rejectTicket(_ id: UUID) {
        process(id) { $0.reject(ticket: id, note: ticketNotes[id] ?? "") }
    }

    /// [다시 받아쓰기]·[다시 번역] 전에: 주석 칸에 쓴 글이 있으면 티켓 조각들의 주석에 덧붙이고(실행 취소 한 단계
    /// "주석 고치기") 칸을 비운다. 작업이 조각을 바꿔도 주석은 남거나 새 조각으로 옮겨 간다.
    func commitTicketNote(_ id: UUID) {
        let clean = (ticketNotes[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ticketNotes[id] = nil
        guard !clean.isEmpty, let editor, let ticket = editableTicket(id) else { return }
        editor.appendNote(clean, cues: Set(ticket.cueIDs), in: ticket.setID)
    }

    /// 지금 티켓 동작을 할 수 있다(고친 티켓이 있고 자막셋이 잠기지 않았다). 메뉴의 ⌘↩·⌘⌫에 쓴다.
    var canProcessSelectedTicket: Bool { !isActiveSetLocked && selectedTicket != nil }

    /// 조각을 고르면 그 조각이 든 (보이는) 티켓을 고른다. 고른 티켓에 든 조각이면 그대로 두고, 티켓이 없는 조각이면
    /// 고른 티켓을 푼다(⌘↩·⌘⌫가 보고 있지 않은 티켓을 처리하지 않게). 선택을 풀면(nil) 그대로 둔다.
    func adoptTicket(containing cueID: UUID?) {
        guard let cueID, selectedTicket?.cueIDs.contains(cueID) != true else { return }
        selectedTicketID = visibleTickets.first { $0.cueIDs.contains(cueID) }?.id
    }

    #if DEBUG
    /// 디버그 메뉴 "티켓 예시 넣기": 가짜 LLM 없이 패널을 보려고 지금 자막셋에 고침(작품 원어 한 조각), 의심(작품 원어
    /// 두 조각), 원문 변경(번역 언어 한 조각) 티켓을 하나씩 연다. 실행 취소 한 단계. 릴리스 빌드에는 없다.
    func insertSampleTickets() {
        guard let editor, let set = currentSet, let original = originalLanguage, !isActiveSetLocked else { return }
        flushDraft()
        let book = editor.tickets
        var used = Set<UUID>()
        func take(_ language: Language, _ count: Int) -> [Cue] {
            let picked = set.cuesInTimelineOrder.filter { cue in
                !used.contains(cue.id) && !cue.text(language).isEmpty
                    && book.ticket(set: set.id, cue: cue.id, language: language) == nil
            }.prefix(count)
            used.formUnion(picked.map(\.id))
            return Array(picked)
        }
        var samples: [Ticket] = []
        let fix = take(original, 1)
        if !fix.isEmpty {
            samples.append(Ticket(setID: set.id, origin: .source, language: original, level: .fix,
                                  reason: "예시: 문맥상 틀린 말이라 고쳤어요",
                                  changes: fix.map { TicketChange(cueID: $0.id, before: $0.text(original),
                                                                  after: "[예시 고침] " + $0.text(original)) }))
        }
        let suspect = take(original, 2)
        if !suspect.isEmpty {
            samples.append(Ticket(setID: set.id, origin: .source, language: original, level: .suspect,
                                  reason: "예시: 앞뒤 두 줄의 주체가 어긋나 보여요",
                                  changes: suspect.map { TicketChange(cueID: $0.id, before: $0.text(original),
                                                                      after: $0.text(original) + " [예시 의심]") }))
        }
        if let language = set.languages.first(where: { $0 != original }) {
            let changed = take(language, 1)
            if !changed.isEmpty {
                samples.append(Ticket(setID: set.id, origin: .translation, language: language, level: .suspect,
                                      reason: Ticket.sourceChangedReason,
                                      changes: changed.map { TicketChange(cueID: $0.id, before: $0.text(language),
                                                                          after: "") }))
            }
        }
        let opened = editor.open(samples)
        if let first = opened.first {
            selectTicket(first.id)
        } else {
            alertMessage = "예시 티켓을 넣을 조각이 없어요"
        }
    }
    #endif

    private func stepTicket(forward: Bool) {
        let order = currentSet?.cuesInTimelineOrder.map(\.id) ?? []
        guard let next = TicketBook.neighbor(of: selectedTicketID, near: selectedCueID, in: visibleTickets,
                                             order: order, forward: forward) else { return }
        selectTicket(next.id)
    }

    /// 티켓 하나를 처리하고, 고른 티켓이었으면 보이는 목록에서 그다음 티켓을 고른다.
    private func process(_ id: UUID, _ body: (SubtitleDataEditor) -> Void) {
        guard editableTicket(id) != nil, let editor else { return }
        flushDraft()
        let before = visibleTickets
        // 다른 티켓을 고르고 있었으면(인스펙터 카드에서 처리) 고른 것을 옮기지 않는다.
        let follows = selectedTicketID == id || selectedTicket == nil
        body(editor)
        guard follows else { return }
        if let next = TicketBook.successor(of: id, before: before, after: visibleTickets) {
            selectTicket(next.id)
        } else if selectedTicketID == id, selectedTicket == nil {
            selectedTicketID = nil
        }
    }

    /// `ms`에서 가장 가까운 캐시 프레임(앞뒤 2초 안). 없으면 nil.
    func frameURL(forMs ms: Int) -> URL? {
        guard let folder = project?.folder.appendingPathComponent(Self.framesFolderName, isDirectory: true) else {
            return nil
        }
        let nearest = Int((Double(max(0, ms)) / 1000).rounded())
        for second in [nearest, nearest - 1, nearest + 1, nearest - 2, nearest + 2] where second >= 0 {
            let url = folder.appendingPathComponent(FrameSampler.fileName(second: second))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 그 종류의 레인이 숨겨져 있으면 다시 보이게 한다. 티켓을 고를 때 부른다.
    func reveal(kind: SubtitleKind) {
        if hiddenKinds.contains(kind) { hiddenKinds.remove(kind) }
    }

    /// 트랙 머리의 눈 버튼. 고른 조각의 레인을 숨기면 선택을 푼다(보이지 않는 조각을 고치거나 지우지 않게).
    func setHidden(_ kind: SubtitleKind, _ hidden: Bool) {
        guard hidden != hiddenKinds.contains(kind) else { return }
        if hidden {
            if selectedClip?.kind == kind { select(nil) }
            hiddenKinds.insert(kind)
        } else {
            hiddenKinds.remove(kind)
        }
    }

    /// 지금 자막셋의 티켓이고 그 자막셋이 잠겨 있지 않으면 그 티켓.
    private func editableTicket(_ id: UUID) -> Ticket? {
        guard !isActiveSetLocked, let currentSetID,
              let ticket = editor?.tickets.tickets.first(where: { $0.id == id }),
              ticket.setID == currentSetID else { return nil }
        return ticket
    }

    // MARK: 작품 노트

    /// 프로젝트 폴더의 `notes.md`.
    var notesURL: URL? { project?.folder.appendingPathComponent("notes.md") }

    /// `notes.md`를 읽는다. 없거나 읽지 못하면 프로젝트 이름으로 만든 빈 틀.
    func loadNotes() -> NotesDocument {
        if let url = notesURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            return NotesDocument(markdown: text)
        }
        return NotesDocument.template(title: project?.name ?? "")
    }

    func writeNotes(_ notes: NotesDocument) throws {
        guard let url = notesURL else { return }
        try notes.markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 노트 패널에 지금 프로젝트의 노트를 연다.
    func openNotes() {
        guard let url = notesURL else { return }
        notes.open(text: loadNotes().markdown) { text in
            try NotesDocument(markdown: text).markdown.write(to: url, atomically: true, encoding: .utf8)
        } onError: { [weak self] error in
            self?.report(error)
        }
    }

    /// LLM이 노트를 쓰기 전에 부른다. 패널에 쓰던 내용을 먼저 저장하고 패널을 읽기 전용으로 둔다.
    func beginNotesWrite() {
        notes.flush()
        notes.isLocked = true
    }

    /// LLM이 노트를 다 썼다. 패널을 풀고 노트를 다시 읽는다.
    func endNotesWrite() {
        notes.isLocked = false
        guard project != nil else { return }
        notes.reload(text: loadNotes().markdown)
    }
}
