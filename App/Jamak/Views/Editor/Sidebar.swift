import JamakCore
import SwiftUI

/// 왼쪽 사이드바(설계 7절): (작업 중) 진행 기록, 티켓 패널. 자막셋 목록은 인스펙터의 "자막셋" 탭에 있다.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation

    /// 진행 기록의 내용 높이. 스크롤 영역을 내용만큼만 차지하게 한다.
    @State private var topHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // 진행 기록은 내용만큼 차지하되, 창이 낮으면 스크롤된다.
            // 티켓 패널이 먼저 최소 높이를 받고(우선순위가 낮은 쪽이 최소를 먼저 받는다) 나머지를 위가 쓴다.
            if generation.isRunning, generation.isWorkflowJob {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        RunLogSection()
                        divider
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: topHeight)
                .layoutPriority(1)
            }
            TicketPanel()
                .frame(minHeight: Self.panelMinHeight, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg1)
    }

    /// 창이 아무리 낮아도 티켓 패널이 남기는 높이(머리·거르기 칩과 몇 줄).
    private static let panelMinHeight: CGFloat = 200

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6)
    }
}

// MARK: 진행 기록

private struct RunLogSection: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "진행") {}
                .padding(.horizontal, -14)
            VStack(spacing: 0) {
                ForEach(Array(previous.enumerated()), id: \.offset) { _, step in
                    row(title: step.title, state: .done, trailing: "이전에 끝남")
                }
                ForEach(generation.runLog) { entry in
                    if let end = entry.endedAt {
                        row(title: entry.stage.rawValue, state: .done,
                            trailing: Self.duration(end.timeIntervalSince(entry.startedAt)))
                    } else {
                        row(title: entry.stage.rawValue, state: .running(generation.isIndeterminate ? nil : generation.fraction),
                            trailing: generation.chunkDetail ?? percent)
                    }
                }
            }
            Text("취소하거나 앱을 꺼도 끝난 구간은 저장돼 있어요. 다음에 이어서 해요.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var percent: String? {
        generation.isIndeterminate ? nil : "\(Int((generation.fraction * 100).rounded()))%"
    }

    /// 이번 실행 기록에 없지만 작업 자막셋의 저장된 진행에서 이미 끝난 단계(받아쓰기·분석·원문 검토).
    private var previous: [GenerationController.WorkflowStep] {
        guard var state = model.project?.state, let setID = model.jobSetID else { return [] }
        // 진행은 자막셋마다 따로다. 작업 자막셋의 생성 진행만 본다.
        state.setGeneration = state.setGeneration?.filter { $0.key == setID }
        state.setTranslations = nil
        let translating = generation.translationTarget != nil
        let covered = Set(generation.runLog.compactMap { GenerationController.workflowStep(of: $0.stage, translating: translating) })
        let hasSource = !(model.editor?.set(setID)?.cues.isEmpty ?? true)
        let status = WorkflowStatus(state: state, hasSourceSet: hasSource)
        let done: [(GenerationController.WorkflowStep, StepState)] = [
            (.transcribe, status.transcribe), (.analyze, status.analyze), (.correct, status.correct),
        ]
        return done.filter { $0.1 == .done && !covered.contains($0.0) }.map(\.0)
    }

    private enum RowState { case done, running(Double?) }

    private func row(title: String, state: RowState, trailing: String?) -> some View {
        HStack(spacing: 8) {
            dot(state).frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isRunning(state) ? Theme.text : Theme.text2)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private func isRunning(_ state: RowState) -> Bool {
        if case .running = state { true } else { false }
    }

    @ViewBuilder private func dot(_ state: RowState) -> some View {
        switch state {
        case .done:
            Circle().fill(Theme.fixed)
        case .running(let fraction):
            ZStack {
                Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                if let fraction {
                    Circle().trim(from: 0, to: max(0.04, fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6))
                        .frame(width: 7, height: 7)
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }
            }
        }
    }

    /// `m:ss`.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
