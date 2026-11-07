import JamakCore
import SwiftUI

/// 인스펙터(설계 5절): "조각" / "자막셋" / "작품 노트" 탭. 탭은 `model.inspectorTab`이 정한다.
struct InspectorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabs()
            switch model.inspectorTab {
            case .clip: ClipTab()
            case .set: SetTab()
            case .notes: NotesPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg1)
    }
}

/// 탭 머리(시안 .insp-tabs): 현재 탭은 글자를 밝게 하고 accent 2px 밑줄을 긋는다.
private struct InspectorTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            tab("조각", .clip)
            tab("자막셋", .set)
            tab("작품 노트", .notes)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .background(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func tab(_ title: String, _ value: InspectorTab) -> some View {
        let isOn = model.inspectorTab == value
        return Button { model.inspectorTab = value } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Theme.text : Theme.text3)
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, 9)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isOn ? Theme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 인스펙터 안내 문구(선택 없음 등).
private func inspectorNote(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12))
        .foregroundStyle(Theme.text3)
        .lineSpacing(3)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}

/// 인스펙터 칸 이름(시안 .field-l).
private func fieldLabel(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 11))
        .foregroundStyle(Theme.text3)
}

// MARK: 조각 탭

/// "조각" 탭: 선택이 없으면 안내 문구, 있으면 조각 편집(언어마다 칸). 메모를 골랐으면 메모 편집.
private struct ClipTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let memo = model.selectedMemo {
            ScrollView {
                MemoInspector(memo: memo)
                    .id(memo.id)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let cue = model.selectedCue, let set = model.currentSet, let original = model.originalLanguage {
            ScrollView {
                ClipInspector(cue: cue, languages: [original] + set.languages.filter { $0 != original },
                              original: original)
                    .id(cue.id)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            inspectorNote("자막 조각을 선택하면 여기서 언어별 문장과 시간을 고칠 수 있어요.")
        }
    }
}

private enum ClipField: Hashable {
    case start, end
    case body(Language)
}

private struct ClipInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let cue: Cue
    /// 자막셋의 언어(작품 원어 먼저).
    let languages: [Language]
    let original: Language

    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focus: ClipField?

    /// 시간·종류를 고칠 때 쓰는 조각 보기(문장은 쓰지 않는다).
    private var clip: SubtitleClip {
        SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind, text: cue.text(original))
    }

    var body: some View {
        let locked = model.isActiveSetLocked
        VStack(alignment: .leading, spacing: 14) {
            if locked { LockCard() }
            // 생성 중인 자막셋은 보기만 한다.
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("종류")
                    KindSegment(selection: kindBinding)
                }
                timesRow
            }
            .disabled(locked)
            .opacity(locked ? 0.5 : 1)
            ForEach(languages, id: \.self) { language in
                languageSection(language, locked: locked)
            }
            CueNoteField(cue: cue)
                .disabled(locked)
                .opacity(locked ? 0.5 : 1)
            moreActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            resetTimes()
            takeBodyFocusIfRequested()
        }
        // 다른 탭으로 가면 고치던 칸을 커밋한다(자막셋 탭의 채운 수가 맞고, 언어 삭제 전에 초안이 남지 않는다).
        .onDisappear { model.flushDraft() }
        .onChange(of: model.requestBodyFocus) { takeBodyFocusIfRequested() }
        .onChange(of: cue) {
            if focus != .start && focus != .end { resetTimes() }
        }
        .onChange(of: focus) { old, new in
            if case .body = old, new != old { model.flushDraft() }
            if (old == .start || old == .end) && new != old { commitTimes() }
        }
    }

    /// 시작·끝 입력과 길이(시안 .times).
    private var timesRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            timeField("시작", text: $startText, field: .start)
            timeField("끝", text: $endText, field: .end)
            Text(String(format: "%.2f초", Double(cue.end - cue.start) / 1000))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .fixedSize()
                .padding(.bottom, 7)
        }
    }

    private func timeField(_ label: String, text: Binding<String>, field: ClipField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            TextField(label, text: text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .focused($focus, equals: field)
                .onSubmit { commitTimes() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(focus == field ? Theme.accent : Theme.line, lineWidth: 1)
        }
    }

    /// 한 언어의 칸과 그 칸에 열린 티켓의 검토 카드.
    @ViewBuilder private func languageSection(_ language: Language, locked: Bool) -> some View {
        let ticket = model.ticket(for: cue.id, language: language)
        VStack(alignment: .leading, spacing: 8) {
            LanguageField(cue: cue, language: language, original: original,
                          hasSuspect: ticket?.level == .suspect,
                          isFocused: focus == .body(language), focus: $focus)
                .disabled(locked)
                .opacity(locked ? 0.5 : 1)
            if let ticket {
                ReviewCards(clip: SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind,
                                               text: cue.text(language)),
                            ticket: ticket)
            }
        }
    }

    /// 아래 동작 목록(시안 .more): 이 조각 다시 받아쓰기(음성 조각), 다음 티켓.
    private var moreActions: some View {
        VStack(alignment: .leading, spacing: 2) {
            if cue.kind == .speech {
                retranscribeButton
            }
            Button { model.selectNextTicket() } label: {
                MoreRowLabel(title: "다음 티켓", systemImage: "chevron.right", shortcut: "⌘G")
            }
            .buttonStyle(MoreRowStyle())
            .disabled(model.visibleTickets.isEmpty)
        }
    }

    /// 이 조각만 다시 받아쓴다(이웃 대사는 그대로). 고치던 시간과 본문을 먼저 커밋하고 커밋한 시간으로 한다.
    @ViewBuilder private var retranscribeButton: some View {
        Button {
            commitTimes()
            model.flushDraft()
            guard let current = model.selectedClip, current.id == cue.id else { return }
            generation.runRangeJob(.retranscribeClip(current.id), range: current.start...current.end, model: model)
        } label: {
            MoreRowLabel(title: "이 조각 다시 받아쓰기", systemImage: "mic", shortcut: nil)
        }
        .buttonStyle(MoreRowStyle())
        .disabled(generation.isRunning || !RangeActions.canStart(model))
        .help(RangeActions.languageHelp(model))
    }

    private var kindBinding: Binding<SubtitleKind> {
        Binding(
            get: { cue.kind },
            set: { kind in
                var changed = clip
                changed.kind = kind
                model.commitTiming(changed, actionName: "종류 변경")
            }
        )
    }

    /// 새 조각은 작품 원어 칸에 커서를 둔다.
    private func takeBodyFocusIfRequested() {
        guard model.requestBodyFocus else { return }
        model.requestBodyFocus = false
        // 막 나타난 편집기는 같은 업데이트 안에서 포커스를 받지 못하니 다음 차례에 준다.
        DispatchQueue.main.async { focus = .body(original) }
    }

    private func resetTimes() {
        startText = Timecode.full(cue.start)
        endText = Timecode.full(cue.end)
    }

    /// 입력한 시작·끝이 올바르면(시작 ≥ 0, 끝 ≤ 영상 길이, 길이 ≥ 300ms) 한 번에 커밋한다. 아니면 되돌린다.
    private func commitTimes() {
        guard let start = Timecode.parse(startText), let end = Timecode.parse(endText),
              end - start >= ClipDrag.minLengthMs,
              model.durationMs == 0 || end <= max(model.durationMs, cue.end)
        else {
            if startText != Timecode.full(cue.start) || endText != Timecode.full(cue.end) { NSSound.beep() }
            resetTimes()
            return
        }
        startText = Timecode.full(start)
        endText = Timecode.full(end)
        var changed = clip
        changed.start = start
        changed.end = end
        model.commitTiming(changed, actionName: "시간 수정")
    }
}

// MARK: 메모 편집

private enum MemoField: Hashable {
    case start, end, text
}

/// 장면 메모 편집: 시작·끝 시간과 글. 글은 칸을 떠나거나 ⌘↩를 누르면 한 단계("메모 수정")로 커밋한다.
private struct MemoInspector: View {
    @Environment(AppModel.self) private var model
    let memo: SceneMemo

    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focus: MemoField?

    var body: some View {
        let locked = model.isActiveSetLocked
        VStack(alignment: .leading, spacing: 14) {
            if locked { LockCard() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.memo).frame(width: 4, height: 14)
                    Text("장면 메모")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Text("AI가 이 시간의 자막을 다룰 때 함께 읽어요. 작품 노트보다 먼저 믿어요. 내보내기에는 들어가지 않아요.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                timesRow
                textField
            }
            .disabled(locked)
            .opacity(locked ? 0.5 : 1)
            Button {
                model.deleteSelectedMemo()
            } label: {
                MoreRowLabel(title: "메모 삭제", systemImage: "trash", shortcut: "⌫")
            }
            .buttonStyle(MoreRowStyle())
            .disabled(locked || model.memosHidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            resetTimes()
            takeFocusIfRequested()
        }
        .onDisappear { model.flushDraft() }
        .onChange(of: model.requestMemoFocus) { takeFocusIfRequested() }
        .onChange(of: memo) {
            if focus != .start && focus != .end { resetTimes() }
        }
        .onChange(of: focus) { old, new in
            if old == .text, new != old { model.flushDraft() }
            if (old == .start || old == .end) && new != old { commitTimes() }
        }
    }

    private var timesRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            timeField("시작", text: $startText, field: .start)
            timeField("끝", text: $endText, field: .end)
            Text(String(format: "%.1f초", Double(memo.end - memo.start) / 1000))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text2)
                .fixedSize()
                .padding(.bottom, 7)
        }
    }

    private func timeField(_ label: String, text: Binding<String>, field: MemoField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.text3)
            TextField(label, text: text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .focused($focus, equals: field)
                .onSubmit { commitTimes() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(focus == field ? Theme.accent : Theme.line, lineWidth: 1)
        }
    }

    private var textField: some View {
        let text = model.memoText(of: memo)
        return VStack(alignment: .leading, spacing: 6) {
            fieldLabel("내용")
            TextEditor(text: Binding(get: { model.memoText(of: memo) },
                                     set: { model.setMemoDraft($0, for: memo.id) }))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .text)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(minHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("예: 유리가 마사토에게 이별을 말하는 장면. 둘은 존댓말을 써요.")
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
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focus == .text ? Theme.accent : Theme.line2, lineWidth: 1)
                }
                .accessibilityLabel("메모 내용")
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.flushDraft()
                    return .handled
                }
        }
    }

    /// 새로 만든(또는 칩으로 연) 메모는 글 칸에 커서를 둔다.
    private func takeFocusIfRequested() {
        guard model.requestMemoFocus else { return }
        model.requestMemoFocus = false
        DispatchQueue.main.async { focus = .text }
    }

    private func resetTimes() {
        startText = Timecode.full(memo.start)
        endText = Timecode.full(memo.end)
    }

    /// 입력한 시작·끝이 올바르면(시작 ≥ 0, 끝 ≤ 영상 길이, 길이 ≥ 300ms) 한 번에 커밋한다. 아니면 되돌린다.
    private func commitTimes() {
        guard let start = Timecode.parse(startText), let end = Timecode.parse(endText),
              start >= 0, end - start >= ClipDrag.minLengthMs,
              model.durationMs == 0 || end <= max(model.durationMs, memo.end)
        else {
            if startText != Timecode.full(memo.start) || endText != Timecode.full(memo.end) { NSSound.beep() }
            resetTimes()
            return
        }
        startText = Timecode.full(start)
        endText = Timecode.full(end)
        var changed = memo
        changed.start = start
        changed.end = end
        model.commitMemo(changed, actionName: "메모 시간 수정")
    }
}

/// 한 언어의 입력 칸(시안 .lang-field): 머리(작품 원어 별표, 이름, 글자 수·초당 글자 수, 의심 티켓 표시)와 문장.
/// 빈 칸은 작품 원어로 대신 보인다는 안내와 [이 조각 번역]을 보인다. 안내는 칸에 쓰지 않는다.
private struct LanguageField: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// LLM 설정이 바뀌면 "이 조각 번역"의 비활성·도움말을 다시 정한다.
    @AppStorage(LLMEnvironment.defaultsKey) private var llmSettingsData: Data?
    let cue: Cue
    let language: Language
    let original: Language
    let hasSuspect: Bool
    let isFocused: Bool
    var focus: FocusState<ClipField?>.Binding

    private var isOriginal: Bool { language == original }

    var body: some View {
        let text = model.bodyText(of: cue, language: language)
        let isEmpty = text.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            header(text: text, isEmpty: isEmpty)
            Rectangle().fill(Theme.line).frame(height: 1)
            editor(isEmpty: isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(isFocused ? Theme.accent : Theme.line2, lineWidth: 1)
        }
    }

    private func header(text: String, isEmpty: Bool) -> some View {
        HStack(spacing: 6) {
            if isOriginal {
                Text("★")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            Text(language.displayName)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text)
            if isOriginal {
                Text("작품 원어")
                    .foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
            if isEmpty && !isOriginal {
                translateButton
            } else {
                metrics(text)
            }
            reviewedToggle
            if hasSuspect {
                Text("!")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x2A0B0A))
                    .frame(width: 14, height: 14)
                    .background(Theme.suspect, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("의심")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
    }

    /// 검토됨 표시(이 언어 칸). 켜져 있으면 전체·구간 검토가 이 칸을 건너뛴다. 칸 문장이 바뀌면 풀린다.
    private var reviewedToggle: some View {
        let on = cue.reviewed.contains(language)
        return Button {
            model.setReviewed(!on, cue: cue.id, language: language)
        } label: {
            Image(systemName: on ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 12))
                .foregroundStyle(on ? Theme.accent : Theme.text3)
        }
        .buttonStyle(.plain)
        .disabled(model.isActiveSetLocked)
        .help(on ? "검토됨 · 전체·구간 검토가 이 칸을 건너뛰어요. 누르면 풀어요"
                 : "검토됨으로 표시해요. 전체·구간 검토가 이 칸을 건너뛰어요")
        .accessibilityLabel("\(language.displayName) 검토됨")
        .accessibilityValue(on ? "켬" : "끔")
    }

    /// 이 칸만 번역한다(원문은 작품 원어, 검토 없음). 결과는 실행 취소 한 단계로 들어간다.
    /// 작품 원어 칸이 비었거나, 다른 작업 중이거나, LLM을 쓸 수 없으면 누를 수 없다.
    private var translateButton: some View {
        let textReady = LLMEnvironment.isTextReady(LLMSettings.decode(llmSettingsData))
        let hasSource = !cue.text(original).isEmpty
        return Button {
            model.flushDraft()
            generation.translateCue(cue.id, to: language, model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 10))
                Text("이 조각 번역")
            }
        }
        .buttonStyle(JButtonStyle(role: .secondary, height: 22))
        .disabled(generation.isRunning || model.isActiveSetLocked || !textReady || !hasSource)
        .help(!textReady ? GenerationController.llmSetupNote
              : !hasSource ? "\(original.displayName) 문장이 있어야 번역할 수 있어요"
              : "\(original.displayName) 문장을 \(language.displayName)로 번역해요")
    }

    /// "5자 · 3.1자/초". 읽기 빠듯하면 경고 색.
    private func metrics(_ text: String) -> some View {
        let metrics = CaptionMetrics(text: text, durationMs: cue.end - cue.start)
        return Text("\(metrics.characters)자 · \(String(format: "%.1f", metrics.charsPerSecond))자/초")
            .monospacedDigit()
            .foregroundStyle(metrics.isTooFast ? Theme.warning : Theme.text3)
            .help(metrics.isTooFast ? "읽기 빠듯해요" : "")
    }

    private func editor(isEmpty: Bool) -> some View {
        TextEditor(text: binding)
            .font(.system(size: 14.5))
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .focused(focus, equals: .body(language))
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                if isEmpty && !isOriginal {
                    Text("비어 있어요 · 영상에는 작품 원어(\(original.displayName))로 보여요")
                        .font(.system(size: 12.5))
                        .italic()
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("\(language.displayName) 문장")
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.flushDraft()
                return .handled
            }
    }

    /// 칸에 쓰는 글은 초안으로 두고, 칸을 떠나거나 ⌘↩를 누르면 한 단계로 커밋한다.
    private var binding: Binding<String> {
        Binding(
            get: { model.bodyText(of: cue, language: language) },
            set: { model.setBodyDraft($0, for: cue.id, language: language) }
        )
    }
}

/// 조각 주석: 사람이 이 조각에 대해 확인한 사실. 검토와 번역에 그 줄의 주석으로 간다. 내보내기에는 없다.
/// 고치는 글은 초안으로 두고, 칸을 떠나거나 ⌘↩를 누르면 한 단계("주석 고치기")로 커밋한다.
private struct CueNoteField: View {
    @Environment(AppModel.self) private var model
    let cue: Cue
    @FocusState private var focused: Bool

    var body: some View {
        let text = model.noteText(of: cue)
        VStack(alignment: .leading, spacing: 6) {
            Text("주석")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text2)
            TextEditor(text: Binding(get: { model.noteText(of: cue) },
                                     set: { model.setNoteDraft($0, for: cue.id) }))
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(minHeight: 46)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("예: 여기 おごれ는 명령형이 맞아요. 검토와 번역이 이 글을 따라요.")
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
                .accessibilityLabel("조각 주석")
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.flushDraft()
                    return .handled
                }
                .onChange(of: focused) { _, now in if !now { model.flushDraft() } }
        }
    }
}

// MARK: 자막셋 탭

/// "자막셋" 탭: 위에 자막셋 목록(고르기, 추가·이름 바꾸기·복제·삭제), 아래에 지금 자막셋의 설정(시안 "자막셋 설정":
/// 이름, 언어 목록, 언어 추가·삭제). 모두 실행 취소할 수 있다.
private struct SetTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OriginalLanguageSection()
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14).padding(.bottom, 4)
                SetsSection()
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14).padding(.top, 10)
                if let set = model.currentSet {
                    SectionHeader(title: "자막셋 설정") {}
                    SetSettings(setID: set.id, name: set.name, languages: set.languages,
                                original: model.originalLanguage ?? set.languages[0], cueCount: set.cues.count)
                        .id(set.id)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                } else {
                    inspectorNote("자막셋을 고르면 여기서 이름과 언어를 정할 수 있어요.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: 작품 원어

/// "작품 원어" 고르기. 조각이 하나라도 있으면(어느 자막셋이든) 받아쓰기부터 달라지니 막는다. 작업 중에도 막는다.
/// 바꾸면 프로젝트가 바로 저장되니, 저장 안 된 다른 편집이 있으면 먼저 저장 확인을 거친다.
private struct OriginalLanguageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation

    private var hasCues: Bool { (model.editor?.data.sets ?? []).contains { !$0.cues.isEmpty } }
    private var blocked: Bool { hasCues || generation.isRunning || model.isJobRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "작품 원어") {}
            if let original = model.originalLanguage {
                Picker("작품 원어", selection: Binding(get: { original }, set: choose)) {
                    ForEach(Language.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .disabled(blocked)
                .padding(.horizontal, 14)
                .accessibilityLabel("작품 원어")
                if hasCues {
                    Text("자막이 있으면 바꿀 수 없어요. 받아쓰기부터 달라지기 때문이에요")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func choose(_ language: Language) {
        guard !blocked else { return }
        model.confirmDiscardingChanges {
            // "저장 안 함"이면 버리고 바꾼다(바꾸면 바로 저장하므로, 버리지 않으면 고친 것이 저장된다).
            // 버린 뒤 되돌아온 자막에 조각이 있으면 바꾸지 않는다.
            model.discardUnsavedChanges()
            guard let data = model.editor?.data, !data.sets.contains(where: { !$0.cues.isEmpty }) else { return }
            model.changeOriginalLanguage(to: language)
        }
    }
}

// MARK: 자막셋 목록

/// 이름을 묻는 중인 자막셋 작업.
private enum NamePrompt: Identifiable {
    /// 새 자막셋(지금 자막셋의 언어로, 조각 없이).
    case add
    case rename(CueSet)

    var id: String {
        switch self {
        case .add: "add"
        case .rename(let set): "rename-\(set.id)"
        }
    }
}

private struct SetsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var namePrompt: NamePrompt?
    @State private var nameDraft = ""
    @State private var deleting: CueSet?

    /// 구간 작업은 지금 자막셋에 결과를 넣으니, 그동안은 자막셋을 바꾸지 않는다.
    private var switchBlocked: Bool { generation.rangeJob != nil }
    /// 작업 중에는 자막셋을 더하거나 지우거나 이름을 바꾸지 않는다(실행 취소가 막혀 되돌릴 수 없다).
    private var changesBlocked: Bool { generation.isRunning || model.isJobRunning }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "자막셋") {
                Button {
                    nameDraft = Self.newSetName
                    namePrompt = .add
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.jIcon)
                    .help(changesBlocked ? AppModel.setsBlockedNote : "자막셋 추가")
                    .accessibilityLabel("자막셋 추가")
                    .disabled(changesBlocked || model.currentSet == nil)
            }
            .padding(.trailing, -6)
            VStack(spacing: 2) {
                ForEach(model.editor?.data.sets ?? []) { set in
                    SetRow(cueSet: set)
                        .contextMenu { menu(for: set) }
                }
                .disabled(switchBlocked)
            }
            .padding(.horizontal, 8)
            if model.isActiveSetLocked {
                Text(AppModel.lockedNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
        }
        .alert(promptTitle, isPresented: namePromptShown, presenting: namePrompt) { prompt in
            TextField("이름", text: $nameDraft)
            Button(promptAction(prompt)) { commit(prompt) }
                .disabled(trimmedName.isEmpty)
            Button("취소", role: .cancel) {}
        } message: { prompt in
            if case .add = prompt { Text("언어는 지금 자막셋과 같게 시작하고, 조각은 없어요.") }
        }
        .alert("\"\(deleting?.name ?? "")\" 자막셋을 삭제할까요?", isPresented: deletingShown, presenting: deleting) { set in
            Button("삭제", role: .destructive) { if !changesBlocked { model.deleteSet(set.id) } }
            Button("취소", role: .cancel) {}
        } message: { set in
            Text("조각 \(set.cues.count.formatted())개가 함께 지워져요. ⌘Z로 되돌릴 수 있어요.")
        }
    }

    /// 새 자막셋 이름 칸의 처음 값.
    static let newSetName = "새 자막셋"

    @ViewBuilder private func menu(for set: CueSet) -> some View {
        Group {
            Button("이름 바꾸기…") {
                nameDraft = set.name
                namePrompt = .rename(set)
            }
            Button("복제") { model.duplicateSet(set.id) }
        }
        .disabled(changesBlocked)
        Divider()
        Button("삭제…") { deleting = set }
            .disabled(changesBlocked || !model.canDeleteSet(set.id))
    }

    private var trimmedName: String { nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var promptTitle: String {
        switch namePrompt {
        case .rename: "자막셋 이름 바꾸기"
        default: "새 자막셋"
        }
    }

    private func promptAction(_ prompt: NamePrompt) -> String {
        switch prompt {
        case .add: "만들기"
        case .rename: "바꾸기"
        }
    }

    private func commit(_ prompt: NamePrompt) {
        let name = trimmedName
        guard !name.isEmpty else { return }
        guard !changesBlocked else { return }
        switch prompt {
        case .add: model.addSet(named: name)
        case .rename(let set): model.renameSet(set.id, to: name)
        }
    }

    private var namePromptShown: Binding<Bool> {
        Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

/// 자막셋 한 줄(시안 .set): 머리글자 | 이름, 조각 수, 언어 알약(작품 원어는 노란 테두리) | 의심 배지.
/// 지금 자막셋의 설정은 목록 아래에 있다.
private struct SetRow: View {
    @Environment(AppModel.self) private var model
    let cueSet: CueSet
    @State private var isHovering = false

    private var isCurrent: Bool { cueSet.id == model.currentSetID }
    private var isLocked: Bool { model.lockedSetID == cueSet.id }

    /// 작품 원어 먼저.
    private var orderedLanguages: [Language] {
        guard let original = model.originalLanguage else { return cueSet.languages }
        return [original] + cueSet.languages.filter { $0 != original }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                guard !isCurrent else { return }
                model.switchSet(cueSet.id)
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Text(String(cueSet.name.prefix(1)))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text2)
                        .frame(width: 26, height: 26)
                        .background(isCurrent ? Theme.accentSoft : Theme.bg3, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cueSet.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text(countText)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                        LanguagePills(languages: orderedLanguages, original: model.originalLanguage)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(cueSet.name) 자막셋")
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            badge
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Theme.bg3 : isHovering ? Theme.bg2 : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .onHover { isHovering = $0 }
    }

    /// 열린 의심 티켓 수(편집기의 장부, 저장 안 한 변경 포함). 0이면 배지가 없다.
    private var suspectCount: Int {
        model.editor?.tickets.tickets(set: cueSet.id).filter { $0.level == .suspect }.count ?? 0
    }

    /// "1,482조각".
    private var countText: String { "\(cueSet.cues.count.formatted())조각" }

    private var accessibilityValue: String {
        let languages = orderedLanguages.map { $0 == model.originalLanguage ? "\($0.displayName) 원어" : $0.displayName }
        let badge: String? = isLocked ? "잠김" : suspectCount > 0 ? "의심 \(suspectCount)" : nil
        return ([countText] + languages + [badge].compactMap { $0 }).joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        if isLocked {
            JBadge.lock
        } else if suspectCount > 0 {
            JBadge.suspect(suspectCount)
        }
    }
}

/// 자막셋의 언어 알약(시안 .lp). 작품 원어는 노란 테두리에 "원어"가 붙는다.
private struct LanguagePills: View {
    let languages: [Language]
    let original: Language?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(languages, id: \.self) { language in
                let isDefault = language == original
                Text(isDefault ? "\(language.displayName) 원어" : language.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(isDefault ? Theme.accent : Theme.text2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isDefault ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1)
                    }
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }
}


private struct SetSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let setID: UUID
    let name: String
    let languages: [Language]
    let original: Language
    let cueCount: Int

    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var removing: Language?

    /// 작업 중에는 이름과 언어를 바꾸지 않는다(실행 취소가 막혀 되돌릴 수 없다).
    private var blocked: Bool { generation.isRunning || model.isJobRunning }

    /// 작품 원어 먼저.
    private var ordered: [Language] { [original] + languages.filter { $0 != original } }

    private var missing: [Language] { Language.allCases.filter { !languages.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("자막셋 이름과 지원하는 언어를 정해요. 조각마다 지원 언어별 입력 칸이 생겨요.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("이름")
                nameField
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("언어 (한국어 · 일본어 · 영어 중에서)")
                    .fixedSize(horizontal: false, vertical: true)
                languageList
                addRow
                    .padding(.top, 2)
            }
            if blocked {
                Text(AppModel.setSettingsBlockedNote)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("작품 원어는 비어 있는 언어 대신 영상에 보이는 언어예요. 언어를 삭제하면 모든 조각에서 그 언어 문장이 지워져요(실행 취소 가능).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { nameDraft = name }
        .onChange(of: name) { if !nameFocused { nameDraft = name } }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        .alert("\"\(removing?.displayName ?? "")\" 언어를 삭제할까요?", isPresented: removingShown,
               presenting: removing) { language in
            Button("삭제", role: .destructive) { if !blocked { model.removeLanguage(language) } }
            Button("취소", role: .cancel) {}
        } message: { language in
            let count = model.filledCounts[language] ?? 0
            Text("모든 조각에서 \(language.displayName) 문장 \(count.formatted())개와 그 언어의 검토 티켓이 지워져요. ⌘Z로 되돌릴 수 있어요.")
        }
    }

    private var nameField: some View {
        TextField("이름", text: $nameDraft)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .focused($nameFocused)
            .onSubmit { commitName() }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(nameFocused ? Theme.accent : Theme.line, lineWidth: 1)
            }
            .disabled(blocked)
            .help(blocked ? AppModel.setSettingsBlockedNote : "")
            .accessibilityLabel("자막셋 이름")
    }

    /// 이름을 바꾼다(실행 취소 한 단계). 비었거나 같으면 원래 이름으로 되돌린다.
    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocked, !trimmed.isEmpty, trimmed != name {
            model.renameSet(setID, to: trimmed)
        } else {
            nameDraft = name
        }
    }

    /// 언어 목록(시안 .lang-list): 이름, 작품 원어 표시, "n / 전체", 삭제.
    private var languageList: some View {
        let counts = model.filledCounts
        return VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, language in
                if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                languageRow(language, filled: counts[language] ?? 0)
            }
        }
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1) }
    }

    private func languageRow(_ language: Language, filled: Int) -> some View {
        let isOriginal = language == original
        return HStack(spacing: 10) {
            Text(language.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
            if isOriginal {
                Text("작품 원어")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
            Text("\(filled.formatted()) / \(cueCount.formatted())")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
                .accessibilityLabel("채운 조각 \(filled.formatted()) / \(cueCount.formatted())")
            Button("삭제") { removing = language }
                .buttonStyle(JButtonStyle(role: .ghost, height: 22))
                .disabled(blocked || isOriginal)
                .help(isOriginal ? Self.originalUndeletableNote : blocked ? AppModel.setSettingsBlockedNote : "")
                .accessibilityLabel("\(language.displayName) 삭제")
                .accessibilityHint(isOriginal ? Self.originalUndeletableNote : "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 작품 원어의 삭제를 막을 때 보이는 안내.
    static let originalUndeletableNote = "작품 원어는 삭제할 수 없어요."

    /// [언어 추가 ▾]: 자막셋에 없는 언어만 메뉴에 보인다.
    private var addRow: some View {
        HStack(spacing: 6) {
            JMenuButton(items: {
                missing.map { language in (title: language.displayName, action: { model.addLanguage(language) }) }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("언어 추가")
                }
            }
            .disabled(blocked || missing.isEmpty)
            .help(blocked ? AppModel.setSettingsBlockedNote : "")
            .accessibilityLabel("언어 추가")
            if !missing.isEmpty {
                Text("남은 언어: \(missing.map(\.displayName).joined(separator: " · "))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

/// 종류 세그먼트(시안 .kind): 같은 폭 세 칸, 색 점 + 화면/음성/소리.
private struct KindSegment: View {
    @Binding var selection: SubtitleKind

    private static let items: [(SubtitleKind, String)] = [(.screen, "화면"), (.speech, "음성"), (.sound, "소리")]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items, id: \.0) { kind, title in
                Cell(kind: kind, title: title, isSelected: selection == kind) { selection = kind }
            }
        }
        .padding(2)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.line, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("종류")
    }

    private struct Cell: View {
        let kind: SubtitleKind
        let title: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.color(kind))
                        .frame(width: 8, height: 8)
                    Text(title)
                }
                .font(.system(size: 12))
                .foregroundStyle(isSelected || isHovering ? Theme.text : Theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isSelected ? Theme.bg3 : isHovering ? Theme.bg3.opacity(0.5) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

/// 동작 목록 한 줄의 내용: 아이콘, 제목, (있으면) 단축키.
private struct MoreRowLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 14)
            Text(title)
            Spacer(minLength: 0)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 4)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line2, lineWidth: 1) }
            }
        }
    }
}

/// 동작 목록 줄(시안 .more button): 마우스를 올리면 bg2 바탕과 밝은 글자.
private struct MoreRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let active = isEnabled && (isHovering || configuration.isPressed)
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(active ? Theme.text : Theme.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Theme.bg2 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
        }
    }
}
