import AppKit
import JamakCore
import SwiftUI

/// 왼쪽 사이드바의 티켓 패널(설계 7절): 거르기 칩, 지금 자막셋의 열린 티켓(첫 조각 시간 순서), 아래쪽에 고른
/// 티켓의 상세(조각별 비교와 반영·미반영).
struct TicketPanel: View {
    @Environment(AppModel.self) private var model
    /// 상세의 내용 높이. 상세가 내용만큼만 차지하고 나머지를 목록이 쓰게 한다.
    @State private var detailHeight: CGFloat = 0

    var body: some View {
        let open = model.openTickets
        let filter = model.effectiveTicketFilter
        let visible = open.filter(filter.matches)
        let starts = cueStarts
        VStack(spacing: 0) {
            SectionHeader(title: "티켓") {
                Text("\(visible.count)").monospacedDigit()
            }
            if !open.isEmpty {
                TicketFilterChips(open: open, filter: filter)
                    .padding(.bottom, 8)
            }
            list(visible, open: open, starts: starts)
                .frame(minHeight: Self.listMinHeight)
            if let ticket = model.selectedTicket {
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView(.vertical) {
                    TicketDetail(ticket: ticket, starts: starts, focusCueID: model.selectedCueID)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: detailHeight)
                .layoutPriority(1)
            }
        }
    }

    /// 창이 아무리 낮아도 티켓 목록이 남기는 높이(몇 줄).
    private static let listMinHeight: CGFloat = 96

    /// 조각 id → 시작 시간. 편집이 바뀔 때만 다시 읽힌다(재생 위치는 읽지 않는다).
    private var cueStarts: [UUID: Int] {
        Dictionary((model.currentSet?.cues ?? []).map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder private func list(_ visible: [Ticket], open: [Ticket], starts: [UUID: Int]) -> some View {
        if visible.isEmpty {
            VStack {
                Text(open.isEmpty ? "열린 티켓이 없어요" : "이 거르기에 맞는 티켓이 없어요")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { ticket in
                            TicketRow(ticket: ticket, start: ticket.changes.first.flatMap { starts[$0.cueID] } ?? 0,
                                      showsLanguage: model.effectiveTicketFilter.language == nil)
                                .id(ticket.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                // ⌘G나 타임라인으로 고른 티켓이 바뀌면 그 행이 보이게 한다.
                .onChange(of: model.selectedTicketID) { _, id in
                    guard let id, visible.contains(where: { $0.id == id }) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }
}

/// 섹션 머리(시안 .sec-h). 사이드바와 인스펙터 자막셋 탭이 같이 쓴다.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 0)
            trailing()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: 거르기

/// 두 줄 칩: 언어(전체 / 원문 / 번역 언어별)와 단계(전체 / 고침 / 의심). 숫자는 열린 티켓 수다.
private struct TicketFilterChips: View {
    @Environment(AppModel.self) private var model
    let open: [Ticket]
    let filter: TicketFilter

    /// 작품 원어 먼저, 그다음 자막셋의 다른 언어.
    private var languages: [Language] {
        guard let set = model.currentSet, let original = model.originalLanguage else { return [] }
        return [original] + set.languages.filter { $0 != original }
    }

    var body: some View {
        let inLanguage = open.filter { filter.language == nil || $0.language == filter.language }
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    JChip(title: "전체 \(open.count)", isOn: filter.language == nil) { setLanguage(nil) }
                    ForEach(languages, id: \.self) { language in
                        let count = open.filter { $0.language == language }.count
                        JChip(title: "\(TicketText.languageLabel(language, original: model.originalLanguage)) \(count)",
                              isOn: filter.language == language) { setLanguage(language) }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            HStack(spacing: 4) {
                JChip(title: "전체", isOn: filter.level == nil) { setLevel(nil) }
                JChip(title: "고침 \(inLanguage.filter { $0.level == .fix }.count)", isOn: filter.level == .fix) {
                    setLevel(.fix)
                }
                JChip(title: "의심 \(inLanguage.filter { $0.level == .suspect }.count)", isOn: filter.level == .suspect) {
                    setLevel(.suspect)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
    }

    private func setLanguage(_ language: Language?) {
        model.ticketFilter = TicketFilter(language: language, level: filter.level)
    }

    private func setLevel(_ level: Ticket.Level?) {
        model.ticketFilter = TicketFilter(language: filter.language, level: level)
    }
}

// MARK: 티켓 행

/// 티켓 한 줄: [고침]/[의심] 배지, (언어), 첫 조각 시간, 조각 수(2개 이상) | 이유 한 줄.
private struct TicketRow: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    let start: Int
    /// 언어를 거르지 않았으면 원문·번역 언어를 보인다.
    let showsLanguage: Bool
    @State private var isHovering = false

    private var isSelected: Bool { model.selectedTicketID == ticket.id }

    var body: some View {
        Button { model.selectTicket(ticket.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TicketLevelBadge(level: ticket.level)
                    if showsLanguage {
                        Text(language)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                    }
                    Text(Timecode.full(start))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if ticket.changes.count > 1 {
                        Text("\(ticket.changes.count)조각")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                    }
                }
                Text(TicketText.reason(ticket))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.bg3 : isHovering ? Theme.bg2 : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TicketText.levelName(ticket.level)) \(language) \(Timecode.full(start))")
        .accessibilityValue(ticket.changes.count > 1
                            ? "\(ticket.changes.count)조각 · \(TicketText.reason(ticket))" : TicketText.reason(ticket))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var language: String { TicketText.languageLabel(ticket.language, original: model.originalLanguage) }
}

/// [고침]/[의심] 글자 배지.
struct TicketLevelBadge: View {
    let level: Ticket.Level

    var body: some View {
        Text(TicketText.levelName(level))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(level == .fix ? Theme.fixedText : Theme.suspectText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(level == .fix ? Theme.fixed.opacity(0.14) : Theme.suspect.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

// MARK: 상세

/// 고른 티켓의 상세: 머리(단계, 언어, 출처), 이유, 조각마다 시간과 비교(`before` → `after`), 동작 버튼.
/// 사이드바 패널과 인스펙터의 티켓 카드가 같이 쓴다(`showsHeader`가 false면 머리를 빼고).
struct TicketDetail: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket
    /// 조각 id → 시작 시간.
    let starts: [UUID: Int]
    /// 강조할 조각(지금 고른 조각).
    var focusCueID: UUID?
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(spacing: 6) {
                    TicketLevelBadge(level: ticket.level)
                    Text(TicketText.languageLabel(ticket.language, original: model.originalLanguage))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Text(TicketText.source(ticket))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
            Text(TicketText.reason(ticket))
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ticket.changes, id: \.cueID) { change in
                    TicketChangeRow(change: change, start: starts[change.cueID],
                                    isFocused: ticket.changes.count > 1 && change.cueID == focusCueID)
                }
            }
            TicketNoteField(ticket: ticket)
            TicketActionButtons(ticket: ticket)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 티켓의 주석 칸: 여기 쓴 글은 티켓을 처리할 때(반영·미반영·확인, 다시 받아쓰기·다시 번역 전) 티켓 조각들의 주석에
/// 덧붙는다. 주석은 다음 검토와 번역에 "사람이 확인한 사실"로 간다.
private struct TicketNoteField: View {
    @Environment(AppModel.self) private var model
    let ticket: Ticket

    var body: some View {
        let binding = Binding<String>(
            get: { model.ticketNotes[ticket.id] ?? "" },
            set: { model.ticketNotes[ticket.id] = $0.isEmpty ? nil : $0 })
        TextField("주석 (처리할 때 조각에 남아요)", text: binding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1) }
            .disabled(model.isActiveSetLocked)
            .help("여기 쓴 글은 티켓을 처리할 때 이 티켓 조각들의 주석에 덧붙어요. 다음 검토와 번역은 주석을 사람이 확인한 사실로 따라요.")
            .accessibilityLabel("티켓 주석")
    }
}

/// 조각 하나의 변경: 시간(누르면 그 조각으로), 바뀐 글자를 강조한 비교 또는 "제안 없음"과 지금 문장.
private struct TicketChangeRow: View {
    @Environment(AppModel.self) private var model
    let change: TicketChange
    let start: Int?
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    guard let cue = model.currentSet?.cues.first(where: { $0.id == change.cueID }) else { return }
                    model.reveal(kind: cue.kind)
                    model.select(cue.id)
                    model.seek(ms: cue.start)
                } label: {
                    Text(start.map(Timecode.full) ?? "–")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(isFocused ? Theme.accent : Theme.text3)
                }
                .buttonStyle(.plain)
                .help("이 조각으로 가요")
                if change.after.isEmpty {
                    Text("제안 없음")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }
            }
            Group {
                if change.after.isEmpty {
                    Text(change.before)
                        .foregroundStyle(Theme.text)
                } else {
                    Text(TicketText.diff(from: change.before, to: change.after))
                }
            }
            .font(.system(size: 13))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(isFocused ? Theme.accent.opacity(0.6) : Theme.line,
                                                               lineWidth: 1)
            }
            // 고를 수 있는 글에 손쉬운 사용 이름을 덧씌우면 SwiftUI가 이름을 끝없이 다시 찾다 죽는다.
            if !change.meaningBefore.isEmpty {
                meaning
            }
        }
    }

    /// 원문 티켓의 뜻 풀이(내 언어): 제안이 있으면 뜻의 비교, 없으면 지금 뜻.
    private var meaning: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(AppPreferences.userLanguage.displayName)로 보면")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            Group {
                if change.meaningAfter.isEmpty {
                    Text(change.meaningBefore).foregroundStyle(Theme.text2)
                } else {
                    Text(TicketText.diff(from: change.meaningBefore, to: change.meaningAfter))
                }
            }
            .font(.system(size: 12))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 9)
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 티켓의 동작 버튼. 제안이 있으면 [반영] [미반영].
/// 제안 없는 원문 티켓이면 [다시 받아쓰기](화면 글자 조각만이면 [화면 글자 찾기]) [확인],
/// 제안 없는 번역 티켓이면 [다시 번역] [확인](원문 변경 티켓은 [그대로 두기]),
/// 시간이 바뀐 칸 티켓이면 [확인했어요](= 미반영). 좁으면 위아래로 쌓는다.
struct TicketActionButtons: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// LLM 설정이 바뀌면 [다시 번역]의 비활성·도움말을 다시 정한다.
    @AppStorage(LLMEnvironment.defaultsKey) private var llmSettingsData: Data?
    let ticket: Ticket

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(spacing: 6) { buttons }
        }
        .disabled(model.isActiveSetLocked)
        .help(model.isActiveSetLocked ? AppModel.lockedNote : "")
    }

    @ViewBuilder private var buttons: some View {
        switch TicketAction.kind(of: ticket, original: model.originalLanguage) {
        case .review:
            Button { model.applyTicket(ticket.id) } label: { fill("반영") }
                .buttonStyle(.jPrimary)
                .help("반영 (⌘↩)")
            Button { model.rejectTicket(ticket.id) } label: { fill("미반영") }
                .buttonStyle(.jSecondary)
                .help("미반영 (⌘⌫)")
        case .recheck:
            let job = TicketAction.recheckJob(ticket, model: model)
            let enabled = job != nil && !generation.isRunning && RangeActions.canStart(model)
            Button { TicketAction.performPrimary(ticket, model: model, generation: generation) } label: {
                fill(job?.title ?? "다시 받아쓰기")
            }
            .buttonStyle(.jPrimary)
            .disabled(!enabled)
            .help(generation.isRunning ? "다른 작업이 끝나면 할 수 있어요"
                  : "이 티켓의 조각을 \(job?.title ?? "다시 받아쓰기")해요 · \(RangeActions.languageHelp(model)) (⌘↩)")
            Button { model.rejectTicket(ticket.id) } label: { fill("확인") }
                .buttonStyle(.jSecondary)
                .help("지금 원문이 맞다고 보고 티켓을 닫아요 (⌘⌫)")
        case .retranslate:
            let textReady = LLMEnvironment.isTextReady(LLMSettings.decode(llmSettingsData))
            let keep = TicketAction.secondaryTitle(of: ticket, original: model.originalLanguage)
            Button {
                model.commitTicketNote(ticket.id)
                generation.retranslate(ticket: ticket, model: model)
            } label: { fill("다시 번역") }
                .buttonStyle(.jPrimary)
                .disabled(generation.isRunning || !textReady)
                .help(!textReady ? GenerationController.llmSetupNote
                      : generation.isRunning ? "다른 작업이 끝나면 다시 번역할 수 있어요"
                      : "이 조각만 다시 번역해요 (⌘↩)")
            Button { model.rejectTicket(ticket.id) } label: { fill(keep) }
                .buttonStyle(.jSecondary)
                .help("지금 번역을 그대로 둬요 (⌘⌫)")
        case .acknowledge:
            Button { model.rejectTicket(ticket.id) } label: { fill("확인했어요") }
                .buttonStyle(.jPrimary)
                .help("확인했어요 (⌘↩)")
        }
    }

    private func fill(_ title: String) -> some View {
        Text(title).lineLimit(1).fixedSize().frame(maxWidth: .infinity)
    }
}

/// 티켓의 동작 종류와 주 동작(⌘↩).
enum TicketAction {
    /// 제안이 있다: 반영·미반영.
    case review
    /// 제안 없는 원문 티켓: 다시 받아쓰기(또는 화면 글자 찾기)·확인.
    case recheck
    /// 제안 없는 번역 티켓(원문 변경 티켓 포함): 다시 번역·확인(원문 변경이면 그대로 두기).
    case retranslate
    /// 시간이 바뀐 칸 티켓: 확인했어요(미반영과 같다).
    case acknowledge

    /// `original`: 작품 원어. 티켓 언어가 작품 원어면 원문 티켓이다.
    static func kind(of ticket: Ticket, original: Language?) -> TicketAction {
        if ticket.changes.contains(where: { !$0.after.isEmpty }) { return .review }
        if ticket.reason == Ticket.sourceChangedReason { return .retranslate }
        if ticket.reason == Ticket.timingChangedReason { return .acknowledge }
        return ticket.language == original ? .recheck : .retranslate
    }

    /// 메뉴의 주 동작 이름.
    @MainActor static func primaryTitle(of ticket: Ticket?, model: AppModel) -> String {
        guard let ticket else { return "반영" }
        switch kind(of: ticket, original: model.originalLanguage) {
        case .review: return "반영"
        case .recheck: return recheckJob(ticket, model: model)?.title ?? "다시 받아쓰기"
        case .retranslate: return "다시 번역"
        case .acknowledge: return "확인했어요"
        }
    }

    /// 메뉴의 보조 동작 이름.
    static func secondaryTitle(of ticket: Ticket?, original: Language?) -> String {
        guard let ticket else { return "미반영" }
        switch kind(of: ticket, original: original) {
        case .review: return "미반영"
        case .recheck: return "확인"
        case .retranslate: return ticket.reason == Ticket.sourceChangedReason ? "그대로 두기" : "확인"
        case .acknowledge: return "확인했어요"
        }
    }

    /// 제안 없는 원문 티켓의 다시 인식 작업: 티켓 조각을 하나씩 다시 인식한다(`RangeActions.recheck`).
    /// 티켓 밖의 이웃 대사는 건드리지 않는다. 화면 글자 조각만 있으면 이름이 "화면 글자 찾기"다.
    /// 지금 자막셋의 티켓이 아니거나 조각이 없으면 nil. 작업이 조각을 바꾸면 티켓은 함께 닫힌다.
    @MainActor static func recheckJob(_ ticket: Ticket, model: AppModel)
        -> (kind: GenerationController.RangeJobKind, range: ClosedRange<Int>, title: String)? {
        guard ticket.setID == model.currentSetID, let set = model.currentSet else { return nil }
        let ids = Set(ticket.cueIDs)
        let cues = set.cues.filter { ids.contains($0.id) }
        guard let start = cues.map(\.start).min(), let end = cues.map(\.end).max(), start < end else { return nil }
        let title = cues.allSatisfy { $0.kind == .screen } ? "화면 글자 찾기" : "다시 받아쓰기"
        return (.recheckCues(cues.map(\.id)), start...end, title)
    }

    /// 주 동작: 반영, 다시 받아쓰기(화면 글자 찾기), 다시 번역, 확인했어요.
    @MainActor static func performPrimary(_ ticket: Ticket, model: AppModel, generation: GenerationController) {
        switch kind(of: ticket, original: model.originalLanguage) {
        case .review: model.applyTicket(ticket.id)
        case .recheck:
            guard !generation.isRunning, RangeActions.canStart(model),
                  let job = recheckJob(ticket, model: model) else { return }
            model.flushDraft()
            model.commitTicketNote(ticket.id)
            generation.runRangeJob(job.kind, range: job.range, model: model)
        case .retranslate:
            guard !generation.isRunning, LLMEnvironment.isTextReady() else { return }
            model.commitTicketNote(ticket.id)
            generation.retranslate(ticket: ticket, model: model)
        case .acknowledge: model.rejectTicket(ticket.id)
        }
    }
}

/// 티켓 글자: 단계·언어·출처 이름, 이유, 비교.
enum TicketText {
    static func levelName(_ level: Ticket.Level) -> String { level == .fix ? "고침" : "의심" }

    /// 작품 원어면 "원문", 아니면 언어 이름.
    static func languageLabel(_ language: Language, original: Language?) -> String {
        language == original ? "원문" : language.displayName
    }

    /// 출처: 원문 티켓은 "원문"(예전 번역 검토가 낸 원문 티켓도 있어 어느 검토인지 말하지 않는다), 번역 티켓은 "번역 검토".
    static func source(_ ticket: Ticket) -> String {
        ticket.origin == .translation ? "번역 검토" : "원문"
    }

    /// 이유. 비었으면 "확인이 필요해요".
    static func reason(_ ticket: Ticket) -> String {
        let text = ticket.reason.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "확인이 필요해요" : text
    }

    /// 글자 단위 비교: 지운 부분은 빨강 취소선, 넣은 부분은 초록 바탕.
    static func diff(from old: String, to new: String) -> AttributedString {
        var result = AttributedString()
        for part in TextDiff.parts(from: old, to: new) {
            switch part {
            case .same(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.text
                result += run
            case .removed(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.suspectText
                run.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.suspectText.opacity(0.6))
                run.backgroundColor = Theme.suspect.opacity(0.10)
                result += run
            case .added(let text):
                var run = AttributedString(text)
                run.foregroundColor = Theme.insertedText
                run.backgroundColor = Theme.fixed.opacity(0.14)
                result += run
            }
        }
        return result
    }
}
