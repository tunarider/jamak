import Foundation
import JamakCore
import SwiftUI

/// 타임라인 패널(설계 문서 3.5): 위 도구 막대(높이 36), 아래 트랙 머리(폭 150) | 타임라인.
struct TimelinePanel: View {
    @Environment(AppModel.self) private var model
    /// 빈 자막셋 카드의 "srt 가져오기…".
    let onImport: () -> Void
    /// 타임라인에 끌어다 놓은 파일.
    let onDrop: ([URL]) -> Bool
    @State private var lanes = TimelineLaneStore()

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar()
            Group {
                // 자막셋은 늘 하나 이상이라 열린 프로젝트에서는 타임라인이 보인다.
                if model.currentSet == nil {
                    Text("아직 자막이 없어요. srt 파일을 끌어다 놓거나 \"자막 가져오기\"로 추가하세요.")
                        .foregroundStyle(Theme.text3)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 위에 맞춘다. 이름 칸은 높이를 꽉 채우고 타임라인은 내용 높이만 쓰니, 가운데 정렬이면 둘이 어긋난다.
                    HStack(alignment: .top, spacing: 0) {
                        TrackHeads(lanes: lanes)
                            .frame(width: Self.headWidth)
                        TimelineView(lanes: lanes)
                            .overlay(alignment: .top) {
                                // 조각이 없는 자막셋: 눈금자 바로 아래 가운데에 시작 카드(시안 2).
                                if let set = model.currentSet, set.cues.isEmpty {
                                    EmptySetCard(name: set.name, onImport: onImport)
                                        .padding(.top, lanes.metrics.rulerHeight + 8)
                                }
                            }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in onDrop(urls) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg1)
    }

    static let headWidth: CGFloat = 160
}

/// 빈 자막셋 카드(시안 2 .empty-card): 조각 추가, 자동 자막 생성, srt 가져오기.
private struct EmptySetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let name: String
    let onImport: () -> Void

    var body: some View {
        // 작업 중에는 카드의 동작을 모두 막는다(결과를 쓰는 자막셋과 실행 취소가 묶여 있다).
        let editable = model.editor != nil && !generation.isRunning && !model.isJobRunning
        VStack(spacing: 10) {
            Text("\"\(name)\" 자막셋에 아직 조각이 없어요")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("빈 레인을 더블클릭하거나 \"조각 추가\"로 직접 만들 수 있어요.\nAI로 영상에서 자막을 한 번에 만들 수도 있어요.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                AddClipMenu(style: .jSecondary)
                    .disabled(!editable)
                    .fixedSize()
                Button { generation.openGenerationSheet(model: model) } label: {
                    Label("자동 자막 생성…", systemImage: "sparkles").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.jPrimary)
                .disabled(!editable)
                Button("srt 가져오기…", action: onImport)
                    .buttonStyle(.jGhost)
                    .disabled(!editable)
            }
            .help(editable ? "" : "작업 중에는 쓸 수 없어요")
            .padding(.top, 4)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
        .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("빈 자막셋")
    }
}

/// "조각 추가" 메뉴: 종류를 골라 재생 위치에 1초짜리 조각을 만든다(도구 막대와 빈 자막셋 카드).
/// "메모"는 재생 위치에 장면 메모를 만든다.
private struct AddClipMenu: View {
    @Environment(AppModel.self) private var model
    let style: JButtonStyle

    var body: some View {
        JMenuButton(style: style, items: {
            [("화면", { add(.screen) }), ("음성", { add(.speech) }), ("소리", { add(.sound) }),
             ("메모", { model.addMemo(at: model.playheadMs) })]
        }) {
            Label("조각 추가", systemImage: "plus").labelStyle(.titleAndIcon)
        }
    }

    private func add(_ kind: SubtitleKind) {
        model.reveal(kind: kind)
        model.addClip(kind: kind, at: model.playheadMs)
    }
}

/// `TimelineContainerView`가 알린 레인 위치. 트랙 머리가 읽는다.
@MainActor @Observable
final class TimelineLaneStore {
    var metrics = TimelineLaneMetrics()
}

// MARK: - 도구 막대

/// [선택|구간] 도구, "스냅", 구간 칩, 오른쪽 줌.
private struct TimelineToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            JSegmented([(TimelineTool.select, "선택 도구", "cursorarrow"),
                        (TimelineTool.range, "구간 도구", "selection.pin.in.out")],
                       selection: $model.timelineTool, iconOnly: true)
                .fixedSize()
            Button { model.snapEnabled.toggle() } label: {
                Label("스냅", systemImage: "ruler").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jGhost(isOn: model.snapEnabled))
            .help("조각을 끌 때 0.1초 단위에 맞춰요. ⌥를 누르고 끌면 잠시 꺼져요")
            .accessibilityAddTraits(model.snapEnabled ? .isSelected : [])
            .fixedSize()
            Button { model.timelinePinned.toggle() } label: {
                Label("고정", systemImage: "pin").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jGhost(isOn: model.timelinePinned))
            .help("켜면 재생 중에 타임라인이 재생 위치를 따라 움직이지 않아요")
            .accessibilityAddTraits(model.timelinePinned ? .isSelected : [])
            .fixedSize()
            Rectangle().fill(Theme.line2).frame(width: 1, height: 18)
            ClipEditButtons()
            if let range = model.selectedRange {
                RangeChip(target: .range(range))
            } else if let clip = model.selectedClip {
                RangeChip(target: .clip(clip))
            }
            Spacer(minLength: 0)
            ZoomControl()
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// 조각 추가(종류를 골라 재생 위치에 1초짜리 조각)와 선택한 조각 삭제(⌫와 같다).
private struct ClipEditButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editable = model.editor != nil && !model.isActiveSetLocked
        HStack(spacing: 4) {
            AddClipMenu(style: .jGhost(isOn: false))
            .disabled(!editable)
            .help(editable ? "재생 위치에 1초짜리 조각을 추가해요. 빈 레인을 더블클릭해도 돼요" : "지금은 자막셋을 고칠 수 없어요")
            .fixedSize()
            Button { model.deleteSelected() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.jIcon(isOn: false))
            .disabled(!editable || (model.selectedCueID == nil && model.selectedMemoID == nil))
            .help(model.selectedMemoID != nil ? "선택한 메모 삭제 (⌫)" : "선택한 조각 삭제 (⌫)")
            .accessibilityLabel(model.selectedMemoID != nil ? "선택한 메모 삭제" : "선택한 조각 삭제")
        }
    }

}

/// 구간 칩: 고른 구간(없으면 고른 조각)과 구간 작업 버튼. 진행과 [취소]는 상태 표시줄에 보인다.
private struct RangeChip: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let target: Target

    /// 칩이 다루는 것: 타임라인에서 끌어 고른 구간, 또는 고른 조각 하나.
    enum Target {
        case range(ClosedRange<Int>)
        case clip(SubtitleClip)

        var range: ClosedRange<Int> {
            switch self {
            case .range(let range): range
            case .clip(let clip): clip.start...max(clip.start, clip.end)
            }
        }

        var isClip: Bool { if case .clip = self { true } else { false } }
    }

    private static let buttonStyle = JButtonStyle(role: .secondary, height: 22)

    var body: some View {
        let range = target.range
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.label(range))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .padding(.trailing, 2)
                    .accessibilityLabel("\(target.isClip ? "조각" : "구간") \(Self.label(range))")
                jobButtons
                translateButton
                reviewButton
                instructionButton
                memoButton
                Button {
                    if target.isClip { model.select(nil) } else { model.selectedRange = nil }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(JButtonStyle(role: .icon, height: 22))
                .help(target.isClip ? "조각 선택 해제" : "구간 선택 해제")
                .accessibilityLabel(target.isClip ? "조각 선택 해제" : "구간 선택 해제")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 26)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
            .fixedSize()
        }
    }

    /// "다시 받아쓰기", "화면 글자 찾기". 다른 작업(구간 작업 포함)이 없을 때만 된다.
    /// 어느 자막셋에서나 그 자막셋의 작품 원어로 받아써 작품 원어 칸에 쓴다(도움말에 보인다).
    /// 조각이면: 음성 조각만 다시 받아쓸 수 있고 이웃 대사는 그대로 둔다(편집 패널의 "이 조각 다시 받아쓰기"와 같다).
    /// 화면 글자 찾기는 그 조각의 시간 구간에서 찾는다.
    @ViewBuilder private var jobButtons: some View {
        let enabled = !generation.isRunning && RangeActions.canStart(model)
        let language = RangeActions.languageHelp(model)
        let range = target.range
        Group {
            switch target {
            case .range:
                jobButton("다시 받아쓰기", .retranscribe, range: range, enabled: enabled,
                          help: "이 구간 다시 받아쓰기 · \(language)")
                jobButton("강하게 받아쓰기", .retranscribeStrong, range: range, enabled: enabled,
                          help: "말소리가 들리는데 대사가 안 잡힐 때: 말이 없다는 판정을 끄고 다시 받아써요. 음악이나 잡음에서 없는 말이 나올 수 있어요 · \(language)")
                jobButton("화면 글자 찾기", .screenText, range: range, enabled: enabled,
                          help: "이 구간의 화면 글자 찾기 · \(language)")
            case .clip(let clip):
                if clip.kind == .speech {
                    jobButton("다시 받아쓰기", .retranscribeClip(clip.id), range: range, enabled: enabled,
                              help: "이 조각만 다시 받아쓰기(이웃 대사는 그대로) · \(language)")
                }
                jobButton("화면 글자 찾기", .screenText, range: range, enabled: enabled,
                          help: "이 조각 시간의 화면 글자 찾기 · \(language)")
            }
        }
    }

    private func jobButton(_ title: String, _ kind: GenerationController.RangeJobKind, range: ClosedRange<Int>,
                           enabled: Bool, help: String) -> some View {
        Button(title) {
            model.flushDraft()
            generation.runRangeJob(kind, range: range, model: model)
        }
        .buttonStyle(Self.buttonStyle)
        .disabled(!enabled)
        .help(help)
    }

    /// 구간이면 "이 구간만 번역"(범위 "고른 구간"), 조각이면 "이 조각만 번역"(범위 "고른 조각").
    private var translateButton: some View {
        let textReady = LLMEnvironment.isTextReady()
        let range = target.range
        let hasCues = target.isClip || !RangeActions.cues(overlapping: range, in: model.currentSet).isEmpty
        let what = target.isClip ? "조각" : "구간"
        return Button("이 \(what)만 번역") {
            generation.openTranslationSheet(model: model, scope: target.isClip ? .selection : .range)
        }
        .buttonStyle(Self.buttonStyle)
        .disabled(generation.isRunning || !hasCues || !textReady)
        .help(!textReady ? GenerationController.llmSetupNote
              : !hasCues ? "이 구간에 조각이 없어요" : "이 \(what)의 조각을 번역해요")
    }

    /// "검토": 출력 언어가 작품 원어나 "전체"면 원문 검토, 번역 언어면 그 언어의 번역 검토.
    /// 대상은 구간과 겹치는 조각이거나 고른 조각이다.
    private var reviewButton: some View {
        let textReady = LLMEnvironment.isTextReady()
        let kind = GenerationController.chipReviewKind(model)
        let targets: Set<UUID> = switch target {
        case .range(let range): RangeActions.cues(overlapping: range, in: model.currentSet)
        case .clip(let clip): [clip.id]
        }
        let what = target.isClip ? "조각" : "구간"
        let canReview = GenerationController.canReview(model, kind: kind)
        return Button("검토") {
            model.flushDraft()
            // 조각 검토는 검토됨이어도 다시 본다. 구간 검토는 검토됨 칸을 건너뛴다.
            generation.startReview(model: model, kind: kind, targets: targets, skipReviewed: !target.isClip)
        }
        .buttonStyle(Self.buttonStyle)
        .disabled(generation.isRunning || targets.isEmpty || !textReady || !canReview)
        .help(!textReady ? GenerationController.llmSetupNote
              : targets.isEmpty ? "이 구간에 조각이 없어요"
              : !canReview ? "검토할 문장이 없어요"
              : RangeActions.reviewHelp(kind, what: what))
    }

    /// "지시 검토…": 지시를 써서 이 구간·조각을 검토하는 시트를 띄운다.
    private var instructionButton: some View {
        let textReady = LLMEnvironment.isTextReady()
        let targets: Set<UUID> = switch target {
        case .range(let range): RangeActions.cues(overlapping: range, in: model.currentSet)
        case .clip(let clip): [clip.id]
        }
        let what = target.isClip ? "조각" : "구간"
        return Button("지시 검토…") {
            model.flushDraft()
            generation.openInstructionReview(model: model, targets: targets, scopeTitle: "고른 \(what)")
        }
        .buttonStyle(Self.buttonStyle)
        .disabled(generation.isRunning || targets.isEmpty || !textReady)
        .help(!textReady ? GenerationController.llmSetupNote
              : targets.isEmpty ? "이 구간에 조각이 없어요"
              : "지시를 써서 이 \(what)을 검토해요. 지시에 맞는 곳만 티켓으로 받아요")
    }

    /// "메모": 이 시간과 겹치는 메모가 있으면 그 메모를 고르고, 없으면 이 시간으로 새 메모를 만든다.
    private var memoButton: some View {
        let range = target.range
        let existing = model.currentSet?.memos(overlapping: range).isEmpty == false
        let editable = model.editor != nil && !model.isActiveSetLocked
        let what = target.isClip ? "조각" : "구간"
        return Button("메모") { model.openMemo(for: range) }
            .buttonStyle(Self.buttonStyle)
            .disabled(!existing && !editable)
            .help(existing ? "이 \(what)과 겹치는 장면 메모를 열어요"
                  : !editable ? "지금은 자막셋을 고칠 수 없어요"
                  : "이 \(what) 시간으로 장면 메모를 만들어요. AI 작업에 장면 설명으로 함께 보내요")
    }

    /// `00:14:20.0 – 00:14:31.5`.
    static func label(_ range: ClosedRange<Int>) -> String {
        "\(Timecode.tenths(range.lowerBound)) – \(Timecode.tenths(range.upperBound))"
    }
}

/// 줌: [−] 눈금(로그) [+]. 값은 `pxPerSecond` 하나라 ⌘=/⌘-·⌘스크롤·집기와 늘 맞물린다.
private struct ZoomControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Button { model.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus").font(.system(size: 10)) }
                .buttonStyle(JButtonStyle(role: .icon, height: 24))
                .help("축소")
                .accessibilityLabel("축소")
            ZoomTrack()
            Button { model.zoom(by: 1.5) } label: { Image(systemName: "plus").font(.system(size: 10)) }
                .buttonStyle(JButtonStyle(role: .icon, height: 24))
                .help("확대")
                .accessibilityLabel("확대")
        }
    }
}

/// 줌 눈금(시안 .zoom .track: 폭 110, 굵기 3, 손잡이 11). `pxPerSecond`의 범위를 로그 눈금으로 쓴다.
private struct ZoomTrack: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 110

    var body: some View {
        let fraction = ZoomScale.fraction(model.pxPerSecond)
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.line2).frame(width: Self.width, height: 3)
            Capsule().fill(Theme.text2).frame(width: Self.width * fraction, height: 3)
            Circle().fill(Theme.text).frame(width: 11, height: 11)
                .offset(x: Self.width * fraction - 5.5)
        }
        .frame(width: Self.width, height: 20)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            model.pxPerSecond = ZoomScale.pxPerSecond(fraction: value.location.x / Self.width)
        })
        .help("타임라인 줌")
        // 손쉬운 사용에는 같은 값의 슬라이더로 보인다(값 읽기와 올리기·내리기).
        .accessibilityRepresentation {
            Slider(value: Binding(get: { ZoomScale.fraction(model.pxPerSecond) },
                                  set: { model.pxPerSecond = ZoomScale.pxPerSecond(fraction: $0) }),
                   in: 0...1) { Text("타임라인 줌") }
        }
    }
}

/// 줌 눈금의 로그 변환. 범위는 `TimelineGeometry.pxPerSecondRange`.
enum ZoomScale {
    static func fraction(_ px: Double) -> Double {
        let range = TimelineGeometry.pxPerSecondRange
        let f = log(px / range.lowerBound) / log(range.upperBound / range.lowerBound)
        return min(max(f, 0), 1)
    }

    static func pxPerSecond(fraction: Double) -> Double {
        let range = TimelineGeometry.pxPerSecondRange
        let f = min(max(fraction, 0), 1)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, f)
    }
}

// MARK: - 트랙 머리

/// 레인마다 색 막대, 이름, 조각 수, 눈(숨기기)·휴지통(트랙 비우기) 버튼. 잠긴 자막셋이면 버튼 대신 자물쇠.
/// 줄은 `TimelineNSView`의 레인 위치·높이에 맞추고, 세로 스크롤을 따라간다.
private struct TrackHeads: View {
    @Environment(AppModel.self) private var model
    let lanes: TimelineLaneStore

    var body: some View {
        // 조각 수는 자막셋이 바뀔 때만 센다(스크롤로 줄만 움직일 때는 `TrackHeadRows`만 다시 그린다).
        let set = model.currentSet
        let counts = Self.counts(set?.cues.map(\.kind) ?? [], memoCount: set?.memos.count ?? 0)
        var hidden = Set(model.hiddenKinds.map(TimelineLane.kind))
        if model.memosHidden { hidden.insert(.memo) }
        return TrackHeadRows(lanes: lanes, counts: counts, hidden: hidden, locked: model.isActiveSetLocked)
    }

    private static func counts(_ kinds: [SubtitleKind], memoCount: Int) -> [TimelineLane: Int] {
        var counts: [TimelineLane: Int] = [.memo: memoCount]
        for kind in kinds { counts[.kind(kind), default: 0] += 1 }
        return counts
    }
}

private struct TrackHeadRows: View {
    @Environment(AppModel.self) private var model
    let lanes: TimelineLaneStore
    let counts: [TimelineLane: Int]
    let hidden: Set<TimelineLane>
    let locked: Bool

    var body: some View {
        let metrics = lanes.metrics
        ZStack(alignment: .topLeading) {
            ForEach(metrics.lanes, id: \.lane) { lane in
                TrackHead(lane: lane.lane, count: counts[lane.lane] ?? 0, isHidden: hidden.contains(lane.lane),
                          locked: locked)
                    .frame(width: TimelinePanel.headWidth, height: lane.height)
                    .offset(y: lane.y - metrics.offsetY)
            }
            // 눈금자 칸. 레인보다 위에 두어 세로 스크롤 때 가린다.
            Theme.bg1
                .frame(width: TimelinePanel.headWidth, height: metrics.rulerHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        // 줄들은 레인 높이 그대로라 칸보다 클 수 있다. 칸 높이를 넘겨 패널을 밀어내지 않게 최소를 0으로 둔다.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Theme.bg1)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

private struct TrackHead: View {
    @Environment(AppModel.self) private var model
    let lane: TimelineLane
    let count: Int
    let isHidden: Bool
    let locked: Bool
    @State private var confirmingClear = false

    private var color: Color {
        switch lane {
        case .kind(let kind): Theme.color(kind)
        case .memo: Theme.memo
        }
    }

    /// 조각이면 "조각", 메모면 "메모"(개수 읽기와 비우기 확인에 쓴다).
    private var unit: String { lane == .memo ? "메모" : "조각" }

    var body: some View {
        let name = TimelinePalette.laneName(lane)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(isHidden ? 0.35 : 1))
                .frame(width: 4)
                .padding(.vertical, 8)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHidden ? Theme.text3 : Theme.text)
            Spacer(minLength: 0)
            Text(count.formatted())
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
                .accessibilityLabel("\(unit) \(count)개")
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 22, height: 22)
                    .help(AppModel.lockedNote)
                    .accessibilityLabel("잠김")
            } else {
                HStack(spacing: 2) {
                    Button {
                        switch lane {
                        case .kind(let kind): model.setHidden(kind, !isHidden)
                        case .memo: model.setMemosHidden(!isHidden)
                        }
                    } label: {
                        Image(systemName: isHidden ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(JButtonStyle(role: .icon, isOn: isHidden, height: 24))
                    .help(isHidden ? "트랙 보이기" : "트랙 숨기기")
                    .accessibilityLabel("\(name) \(isHidden ? "트랙 보이기" : "트랙 숨기기")")
                    Button {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(JButtonStyle(role: .icon, height: 24))
                    .disabled(count == 0)
                    .help("트랙 비우기")
                    .accessibilityLabel("\(name) 트랙 비우기")
                }
            }
        }
        .confirmationDialog(lane == .memo ? "장면 메모 \(count.formatted())개를 모두 지울까요?"
                                : "\(name) 트랙의 조각 \(count.formatted())개를 모두 지울까요?",
                            isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("모두 지우기", role: .destructive) {
                switch lane {
                case .kind(let kind): model.clearTrack(kind)
                case .memo: model.clearMemos()
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(lane == .memo ? "이 자막셋의 메모만 지워요. 자막 조각은 그대로예요. ⌘Z로 되돌릴 수 있어요."
                 : "이 자막셋의 모든 언어 문장과 검토 티켓도 함께 지워요. ⌘Z로 되돌릴 수 있어요.")
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) 트랙")
    }
}
