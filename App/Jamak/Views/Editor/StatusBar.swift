import JamakCore
import SwiftUI

/// 편집 화면 맨 아래 상태 표시줄(높이 28).
/// 왼쪽: 저장 상태, 잠금, 선택 요약. 가운데: 실행 중인 작업과 [취소]. 오른쪽: LLM 상태(텍스트·비전)와 토큰 사용량.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// LLM 설정이 바뀌면 요약을 다시 그린다.
    @AppStorage(LLMEnvironment.defaultsKey) private var llmSettingsData: Data?

    var body: some View {
        HStack(spacing: 14) {
            saveState
            if let lockedID = model.lockedSetID, let locked = model.editor?.set(lockedID) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("\(locked.name) 잠김")
                }
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 5))
                .help(AppModel.lockedNote)
            }
            if let clip = model.selectedClip {
                Text("선택: \(TimelinePalette.laneName(clip.kind)) 1조각")
            }
            Spacer(minLength: 0)
            if isJobShown {
                JobProgress().layoutPriority(1)
                Spacer(minLength: 0)
            }
            LLMStatus(settings: LLMSettings.decode(llmSettingsData))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Theme.bg0)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var saveState: some View {
        // 시안: 저장됨은 초록, 저장 안 된 변경은 노랑.
        Text(model.isDirty ? "● 저장 안 된 변경" : "● 저장됨")
            .foregroundStyle(model.isDirty ? Theme.accent : Theme.fixedText)
    }

    private var isJobShown: Bool { generation.stage != nil || generation.rangeJob != nil }
}

/// 실행 중인 작업: (구간 작업이면 그 이름과 구간) 단계 이름, "구간 n/m", 막대, %, [취소].
private struct JobProgress: View {
    @Environment(GenerationController.self) private var generation

    var body: some View {
        HStack(spacing: 8) {
            if let job = generation.rangeJob {
                Text("\(Self.name(job.kind)) · \(RangeJobPlan.label(job.range))")
                    .monospacedDigit()
            }
            Text(generation.stageTitle)
                .foregroundStyle(Theme.text2)
            if let detail = generation.chunkDetail {
                Text(detail).monospacedDigit()
            }
            ProgressBar(fraction: generation.isIndeterminate ? nil : generation.fraction)
            if !generation.isIndeterminate {
                Text("\(Int((generation.fraction * 100).rounded(.down)))%")
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            }
            // 파일을 옮기는 동안은 멈출 수 없다.
            if generation.stage != .moving {
                Button("취소") { generation.cancel() }
                    .buttonStyle(.jCompact)
            }
        }
        .lineLimit(1)
        .foregroundStyle(Theme.text2)
    }

    static func name(_ kind: GenerationController.RangeJobKind) -> String {
        switch kind {
        case .retranscribe: "이 구간 다시 받아쓰기"
        case .retranscribeStrong: "이 구간 강하게 받아쓰기"
        case .screenText: "화면 글자 찾기"
        case .retranscribeClip: "이 조각 다시 받아쓰기"
        case .recheckCues: "티켓 조각 다시 받아쓰기"
        }
    }
}

/// 시안의 `.bar`: 폭 180, 높이 4. `fraction`이 nil이면 진행률을 모르는 상태로 조각이 오간다.
private struct ProgressBar: View {
    let fraction: Double?
    @State private var phase = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.line2)
            if let fraction {
                Capsule().fill(Theme.accent)
                    .frame(width: 180 * min(max(fraction, 0), 1))
            } else {
                Capsule().fill(Theme.accent)
                    .frame(width: 54)
                    .offset(x: phase ? 126 : 0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
                    }
                    .onDisappear { phase = false }
            }
        }
        .frame(width: 180, height: 4)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("진행")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "진행 중")
    }
}
