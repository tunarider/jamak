import JamakCore
import JamakLLM
import SwiftUI

/// 상태 표시줄 오른쪽 끝: 역할(텍스트, 비전)마다 점·화살표·모델 한 칸. 누르면 토큰 사용량 팝업이 열린다.
/// 점과 화살표는 `RoleCell`이 `meter.text/vision`만 읽어 그리므로, 요청이 오갈 때 상태 표시줄의 다른 곳은 다시 그려지지 않는다.
struct LLMStatus: View {
    let settings: LLMSettings
    @State private var popoverShown = false

    var body: some View {
        HStack(spacing: 8) {
            if let text = textModel {
                RoleCell(role: .text, label: "텍스트", detail: text, shown: $popoverShown)
                Text("|").foregroundStyle(Theme.line2).fixedSize()
                RoleCell(role: .vision, label: "비전", detail: visionModel, shown: $popoverShown)
            } else {
                Button { popoverShown.toggle() } label: { Text("LLM 설정 안 됨").foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
            }
        }
        .lineLimit(1)
        .popover(isPresented: $popoverShown, arrowEdge: .top) { UsagePopover() }
    }

    /// "<프로바이더> · <모델>". 텍스트 모델을 쓸 수 없으면 nil.
    private var textModel: String? {
        guard LLMEnvironment.isTextReady(settings), let text = settings.textModel,
              let provider = settings.provider(id: text.providerID) else { return nil }
        return "\(provider.name) · \(text.model)"
    }

    private var visionModel: String? {
        guard let vision = settings.visionModel, !vision.model.isEmpty,
              let provider = settings.provider(id: vision.providerID) else { return nil }
        return "\(provider.name) · \(vision.model)"
    }
}

/// 역할 한 칸. `meter`의 그 역할 활동만 읽는다.
private struct RoleCell: View {
    @Environment(AppModel.self) private var model
    let role: LLMRoleKind
    let label: String
    /// nil이면 이 역할을 쓰지 않는다(비전 미설정).
    let detail: String?
    @Binding var shown: Bool

    var body: some View {
        let activity = role == .text ? model.meter.text : model.meter.vision
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(activity.active > 0 ? Theme.fixed : Theme.text3)
                    .frame(width: 6, height: 6)
                arrow(activity)
                    .frame(width: 8)
                Text(label).foregroundStyle(Theme.text2).fixedSize()
                // 모델 이름이 길면 이름이 먼저 잘린다.
                Text(detail ?? "비전 사용 안 함").foregroundStyle(Theme.text3)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) 모델")
        .accessibilityValue(value(activity))
    }

    @ViewBuilder private func arrow(_ activity: LLMMeter.RoleActivity) -> some View {
        if activity.receiving > 0 {
            Text("↓").foregroundStyle(Theme.fixedText)
        } else if activity.active > 0 {
            Text("↑").foregroundStyle(Theme.speech)
        } else {
            Color.clear
        }
    }

    private func value(_ activity: LLMMeter.RoleActivity) -> String {
        // 일부 보조 도구는 레이블을 읽지 않으니 값에도 역할을 넣는다.
        guard let detail else { return "\(label) 모델 사용 안 함" }
        if activity.receiving > 0 { return "\(label) 모델 \(detail), 통신 중, 응답 받는 중" }
        if activity.active > 0 { return "\(label) 모델 \(detail), 통신 중, 요청 보내는 중" }
        return "\(label) 모델 \(detail), 대기 중"
    }
}

/// 이 프로젝트의 작업별 토큰 사용량.
private struct UsagePopover: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var confirming = false

    private static let numberWidth: CGFloat = 84

    var body: some View {
        let meter = model.meter
        let usage = meter.usage
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("토큰 사용량").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            VStack(spacing: 0) {
                columns { header("작업").frame(maxWidth: .infinity, alignment: .leading) }
                    numbers: { header("입력"); header("출력"); header("합계") }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                ForEach(LLMTask.allCases, id: \.self) { task in
                    let u = usage.usage(task)
                    let running = meter.runningTask == task && generation.isRunning
                    columns { taskCell(task, u, running: running) }
                        numbers: { number(u.input); number(u.output); number(u.total) }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
                let total = usage.total
                columns { Text("합계").foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading) }
                    numbers: { number(total.input, bold: true); number(total.output, bold: true); number(total.total, bold: true) }
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.vertical, 6)
            }
            .padding(.top, 10)
            footer
                .padding(.top, 8)
        }
        .padding(.init(top: 12, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 430)
        .background(Theme.bg1)
    }

    private var subtitle: String {
        guard let name = model.project?.name else { return "이 프로젝트 누적" }
        return "\(name) · 이 프로젝트 누적"
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if confirming {
                Text("정말 지울까요?").font(.system(size: 11)).foregroundStyle(Theme.text2)
                Spacer()
                Button {
                    // 확인하는 사이 작업이 시작됐을 수 있다.
                    if !generation.isRunning {
                        model.meter.reset()
                        model.saveTokenUsage()
                    }
                    confirming = false
                } label: { Text("지우기").foregroundStyle(Theme.suspectText) }
                    .buttonStyle(.jCompact)
                    .disabled(generation.isRunning)
                Button("취소") { confirming = false }
                    .buttonStyle(.jCompact)
            } else {
                Text("서버가 알려준 사용량 기준 · 생각 토큰은 출력에 포함")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                Spacer()
                Button("기록 지우기") { confirming = true }
                    .buttonStyle(.jCompact)
                    .disabled(generation.isRunning)
            }
        }
    }

    /// 작업 칸은 남는 폭을, 숫자 칸은 고정 폭을 쓴다.
    private func columns<L: View, N: View>(@ViewBuilder _ first: () -> L, @ViewBuilder numbers: () -> N) -> some View {
        HStack(spacing: 6) {
            first()
            numbers()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
            .frame(width: title == "작업" ? nil : Self.numberWidth, alignment: title == "작업" ? .leading : .trailing)
    }

    private func taskCell(_ task: LLMTask, _ u: TaskUsage, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if running { Circle().fill(Theme.fixed).frame(width: 6, height: 6) }
                Text(task.title).foregroundStyle(Theme.text)
            }
            HStack(spacing: 0) {
                Text(u.lastModel ?? "—").lineLimit(1).truncationMode(.middle)
                if running { Text(" · 진행 중").fixedSize() }
                if u.missingUsage { Text(" · 일부 사용량 정보 없음").foregroundStyle(Theme.warning).fixedSize() }
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func number(_ n: Int, bold: Bool = false) -> some View {
        Text(n.formatted()).monospacedDigit()
            .font(.system(size: 11.5, weight: bold ? .semibold : .regular))
            .foregroundStyle(bold ? Theme.text : Theme.text2)
            .frame(width: Self.numberWidth, alignment: .trailing)
    }
}
