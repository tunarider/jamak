import JamakCore
import JamakMedia
import SwiftUI

// MARK: - 자동 자막 생성 시트

/// "자동 자막 생성"(설계 2절): 다시 만들 트랙(화면, 음성, 소리)을 고른다. 생성은 인식만 하고 작품 원어 칸에 쓴다.
/// 고른 트랙의 기존 조각(과 그 티켓)만 지우고 다른 트랙과 장면 메모는 그대로 둔다. 지울 조각이 있으면 먼저 알린다.
/// 같은 선택의 멈춘 생성이 있으면 이어서 한다(`GenerationPlan.resumes`). 진행은 자막셋마다 따로다.
struct GenerationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let request: GenerationController.GenerationSheetRequest
    @State private var options: GenerationOptions

    init(request: GenerationController.GenerationSheetRequest) {
        self.request = request
        _options = State(initialValue: request.initial)
    }

    private var set: CueSet? { model.editor?.set(request.setID) }
    private var resumes: Bool { GenerationPlan.resumes(progress: request.saved, options: options) }

    /// 지울 조각의 경고. 이미 조각을 쓴 멈춘 생성을 이어 하면 지우지 않는다.
    private var warning: String? {
        guard let set else { return nil }
        if resumes, request.saved?.replacesExistingCues == false { return nil }
        return options.replacingWarning(in: set, tickets: model.editor?.tickets ?? TicketBook())
    }

    var body: some View {
        let warning = warning
        AISheetFrame(title: "자동 자막 생성", subtitle: "영상에서 \"\(set?.name ?? "")\" 자막셋의 자막을 만들어요.") {
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("언어")
                Text(model.originalLanguage.map { "\($0.displayName) — 작품 원어" } ?? "")
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("언어")
                    .accessibilityValue(model.originalLanguage?.displayName ?? "")
            }
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("트랙")
                SheetCheck(title: "화면", detail: "표지판, 자막 카드 같은 화면 글자를 읽어요", isOn: $options.screenText)
                SheetCheck(title: "음성", detail: "대사를 받아써요 (\(Self.modelName))", isOn: $options.transcribe)
                SheetCheck(title: "소리", detail: "총성, 박수 같은 효과음을 찾아요", isOn: $options.sounds)
                if let warning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            }
            if resumes {
                SheetHint("멈춘 생성을 이어서 해요. 끝난 단계는 건너뛰어요.")
            }
        } footer: {
            Button("취소") { generation.generationSheet = nil }
                .buttonStyle(.jSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                generation.start(model: model, setID: request.setID, options: options)
            } label: {
                Label(warning == nil ? "만들기" : "지우고 새로 만들기", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!options.hasTask || set == nil || generation.isRunning)
        }
    }

    /// 예: "Whisper Large v3"(설정에서 고른 받아쓰기 모델).
    private static var modelName: String {
        let id = GenerationController.selectedModelID
        let name = Transcriber.models.first { $0.id == id }?.displayName ?? id
        return "Whisper " + name.replacingOccurrences(of: " (기본)", with: "")
    }
}

// MARK: - 번역 시트

/// "번역"(시안 3): 범위, 원문 → 번역할 언어, 빈 칸만 채우기. 결과는 같은 조각의 번역할 언어 칸에 쓴다.
/// 원문은 늘 작품 원어이고(설계 3절, 바꿀 수 없음), 번역할 언어에는 작품 원어가 없다.
/// 번역은 검토하지 않는다(검토는 따로 하는 작업이다).
struct TranslationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let request: GenerationController.TranslationSheetRequest
    @State private var scope: GenerationController.TranslationSheetRequest.Scope
    @State private var target: Language
    @State private var fillEmptyOnly = false

    init(request: GenerationController.TranslationSheetRequest) {
        self.request = request
        _scope = State(initialValue: request.scope)
        _target = State(initialValue: request.target)
    }

    /// 원문: 작품 원어(시트를 띄울 때 정해 두었고 바꿀 수 없다).
    private var source: Language { model.originalLanguage ?? request.source }

    private var set: CueSet? { model.editor?.set(request.setID) }

    /// 범위의 조각. 자막셋 전체면 nil.
    private func cueIDs(_ scope: GenerationController.TranslationSheetRequest.Scope) -> Set<UUID>? {
        guard let set else { return [] }
        switch scope {
        case .all:
            return nil
        case .selection:
            guard let id = model.selectedCueID, set.cues.contains(where: { $0.id == id }) else { return [] }
            return [id]
        case .range:
            guard let range = model.selectedRange else { return [] }
            return Set(set.cues.filter { $0.start < range.upperBound && $0.end > range.lowerBound }.map(\.id))
        }
    }

    private func count(_ scope: GenerationController.TranslationSheetRequest.Scope) -> Int {
        cueIDs(scope)?.count ?? set?.cues.count ?? 0
    }

    /// 지금 고른 범위에서 번역할 조각 수.
    private func sourceCount(fillEmptyOnly: Bool) -> Int {
        guard let set else { return 0 }
        return TranslationWrite.sources(in: set, source: source, target: target, scope: cueIDs(scope),
                                        fillEmptyOnly: fillEmptyOnly).count
    }

    private var translationRequest: GenerationController.TranslationRequest {
        GenerationController.TranslationRequest(
            scope: cueIDs(scope).map { .cues($0) } ?? .all, source: source, target: target,
            fillEmptyOnly: fillEmptyOnly)
    }

    private var resumes: Bool {
        scope == .all && GenerationController.resumesTranslation(
            model.project?.state[translation: request.setID, target], translationRequest)
    }

    var body: some View {
        let emptyCount = sourceCount(fillEmptyOnly: true)
        let allCount = sourceCount(fillEmptyOnly: false)
        // 다시 번역하게 될 이미 있는 번역과, 그때 지워지는 그 언어의 티켓.
        let existing = allCount - emptyCount
        let clearedTickets = set.map {
            TranslationWrite.ticketsCleared(in: $0, tickets: model.editor?.tickets ?? TicketBook(), source: source,
                                            target: target, scope: cueIDs(scope))
        } ?? 0
        AISheetFrame(title: "번역", subtitle: "조각 안의 한 언어 문장을 다른 언어 칸으로 옮겨요.") {
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("범위")
                JSegmented([(GenerationController.TranslationSheetRequest.Scope.all,
                             "자막셋 전체 (\(count(.all).formatted()))", nil),
                            (.selection, "선택한 조각 (\(count(.selection).formatted()))", nil),
                            (.range, "고른 구간 (\(count(.range).formatted()))", nil)],
                           selection: $scope)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        SheetLabel("원문")
                        Text("\(source.displayName) — 작품 원어")
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 4)
                            .frame(minHeight: 28)
                            .accessibilityLabel("원문")
                            .accessibilityValue(source.displayName)
                    }
                    Text("→")
                        .foregroundStyle(Theme.text3)
                        .frame(height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        SheetLabel("번역할 언어")
                        SheetDropdown(title: target.displayName, accessibility: "번역할 언어") {
                            Language.allCases.filter { $0 != source }.map { language in
                                JMenuEntry(title: language.displayName) { target = language }
                            }
                        }
                    }
                }
                if let set, !set.languages.contains(target) {
                    SheetHint("\(target.displayName)는 자막셋에 없어서 번역하면서 더해요.")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                SheetCheck(title: "빈 칸만 채우기 (\(emptyCount.formatted())조각)",
                           detail: "이미 있는 번역과 그 티켓은 그대로 둬요", isOn: $fillEmptyOnly)
                if !fillEmptyOnly, existing > 0 {
                    Text(clearedTickets > 0
                         ? "이미 있는 번역 \(existing.formatted())개를 모두 다시 번역하고, 걸린 티켓 \(clearedTickets.formatted())개도 함께 지워져요"
                         : "이미 있는 번역 \(existing.formatted())개를 모두 다시 번역해요")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            if resumes {
                SheetHint("멈춘 번역을 이어서 해요. 끝난 단계는 건너뛰어요.")
            } else if scope != .all {
                SheetHint("고른 조각의 번역은 실행 취소할 수 있어요. 저장은 직접 해요.")
            }
        } footer: {
            Button("취소") { generation.translationSheet = nil }
                .buttonStyle(.jSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                generation.startTranslation(translationRequest, setID: request.setID, model: model)
            } label: {
                Label("번역하기", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(model.originalLanguage == nil || source == target || generation.isRunning || (fillEmptyOnly ? emptyCount : allCount) == 0 && !resumes)
        }
    }

}

/// 지시 검토 시트: 사용자가 쓴 지시를 검토 프롬프트에 넣어, 지시에 맞는 곳만 찾아 고칠 문장을 티켓으로 받는다.
/// 검토할 문장(원문, 번역 언어)을 고르고 지시를 쓴다. 범위는 띄운 곳이 정한다(자막셋 전체, 고른 구간·조각).
struct InstructionReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let request: GenerationController.InstructionReviewRequest
    @State private var choice: Choice
    @State private var instruction: String
    @FocusState private var focused: Bool

    /// 검토할 문장. `nil`은 원문.
    private struct Choice: Equatable { var language: Language? }

    init(request: GenerationController.InstructionReviewRequest, lastInstruction: String) {
        self.request = request
        if case .translation(let language) = request.kind {
            _choice = State(initialValue: Choice(language: language))
        } else {
            _choice = State(initialValue: Choice(language: nil))
        }
        _instruction = State(initialValue: lastInstruction)
    }

    private var kind: ReviewPipeline.Kind { choice.language.map { .translation($0) } ?? .source }

    private func title(_ choice: Choice) -> String {
        guard let language = choice.language else {
            return "원문" + (model.originalLanguage.map { " (\($0.displayName))" } ?? "")
        }
        return "\(language.displayName) 번역"
    }

    private var choices: [Choice] {
        var out: [Choice] = []
        if GenerationController.canReview(model, kind: .source) { out.append(Choice(language: nil)) }
        out += GenerationController.reviewLanguages(model).map { Choice(language: $0) }
        return out
    }

    private var isBlank: Bool { instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var canStart: Bool {
        !isBlank && !generation.isRunning && choices.contains(choice) && model.currentSetID == request.setID
    }

    private func start() {
        guard canStart else { return }
        generation.lastInstruction = instruction
        generation.instructionSheet = nil
        generation.startReview(model: model, kind: kind, targets: request.targets, skipReviewed: false,
                               instruction: instruction)
    }

    var body: some View {
        AISheetFrame(title: "지시 검토",
                     subtitle: "지시에 맞는 곳을 찾아 고칠 문장을 티켓으로 받아요. 지시와 상관없는 곳은 건드리지 않아요.") {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    SheetLabel("검토할 문장")
                    SheetDropdown(title: title(choice), accessibility: "검토할 문장") {
                        choices.map { item in JMenuEntry(title: title(item)) { choice = item } }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SheetLabel("범위")
                    Text(request.scopeTitle + (request.targets.map { " (\($0.count.formatted())조각)" } ?? ""))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                        .accessibilityLabel("범위")
                        .accessibilityValue(request.scopeTitle)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SheetLabel("지시")
                TextEditor(text: $instruction)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .frame(height: 110)
                    .overlay(alignment: .topLeading) {
                        if instruction.isEmpty {
                            Text("예: 先生은 \"선생님\" 대신 \"센세\"로 옮겨 줘.\n예: 이 장면에서 하루토는 미오에게 반말을 써.")
                                .font(.system(size: 12.5))
                                .italic()
                                .foregroundStyle(Theme.text3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent : Theme.line2, lineWidth: 1)
                    }
                    .accessibilityLabel("지시")
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        start()
                        return .handled
                    }
                SheetHint(request.targets == nil
                          ? "검토됨 표시가 있는 칸도 봐요. 티켓은 바로 저장돼요."
                          : "검토됨 표시가 있는 칸도 봐요. 티켓은 실행 취소할 수 있고, 저장은 직접 해요.")
            }
        } footer: {
            Button("취소") { generation.instructionSheet = nil }
                .buttonStyle(.jSecondary)
                .keyboardShortcut(.cancelAction)
            Button(action: start) {
                Label("검토하기", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
        .onAppear { focused = true }
    }
}

// MARK: - 시트 부품(시안 .sheet)

/// 시안 `.sheet`: 폭 460, bg1, 머리(제목·설명), 본문, 바닥(구분선과 버튼).
struct AISheetFrame<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
            HStack(spacing: 8) {
                Spacer()
                footer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .padding(.top, 12)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
        .frame(width: 460, alignment: .leading)
        .background(Theme.bg1)
    }
}

/// 시안 `.lbl`.
struct SheetLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 시안 `.hint`.
struct SheetHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.text3)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// 시안 `.input`(⌄): 누르면 아래에 메뉴가 뜬다.
struct SheetDropdown: View {
    let title: String
    let accessibility: String
    let items: () -> [JMenuEntry]
    @State private var anchor = JMenuAnchor.Anchor()

    var body: some View {
        Button { anchor.popUp(items()) } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(JMenuAnchor(anchor: anchor))
        .accessibilityLabel(accessibility)
        .accessibilityValue(title)
    }
}

/// 시안 `.check`: 체크 상자, 제목, 설명.
struct SheetCheck: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isOn ? Theme.accent : Theme.line2, lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Theme.accentInk)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).foregroundStyle(Theme.text)
                    if let detail { Text(detail).foregroundStyle(Theme.text3) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "켬" : "끔")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 시안 `.opt`: 라디오, 제목, 설명.
struct SheetRadio: View {
    let title: String
    let detail: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle().strokeBorder(isOn ? Theme.accent : Theme.line2, lineWidth: 1.5)
                    if isOn { Circle().fill(Theme.accent).padding(3.5) }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text)
                    if let detail { Text(detail).foregroundStyle(Theme.text3) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "선택됨" : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
