import AppKit
import JamakCore
import SwiftUI

/// 편집 화면 배치(설계 문서 3절).
/// 제목 막대(창 툴바) / 사이드바 | 영상 | 인스펙터 / 타임라인(창 전체 폭) / 상태 표시줄.
struct EditorShell: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// 빈 자막셋 카드 "srt 가져오기…".
    let onImport: () -> Void
    /// 제목 막대 "내보내기".
    let onExport: () -> Void
    /// 타임라인에 끌어다 놓은 파일.
    let onDrop: ([URL]) -> Bool
    /// 제목 막대 폭(AI 묶음을 좁게 그릴지 정한다). 본문은 읽지 않아 창 크기를 바꿔도 셸은 다시 그리지 않는다.
    @State private var titleBar = TitleBarWidths()

    var body: some View {
        VStack(spacing: 0) {
            // 제목 막대 아래 1px 구분선(시스템 구분선은 끈다. `WindowChrome`).
            Rectangle().fill(Theme.line).frame(height: 1)
            JSplitView(axis: .vertical, panes: [
                .init(minimum: 300, initial: nil, content: pane(columns)),
                .init(minimum: 180, initial: 280, content: pane(timelineColumn)),
            ])
            StatusBar()
        }
        // 창 최소 크기 1100×700(제목 막대 52 포함).
        .frame(minWidth: 1100, minHeight: 700 - Self.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleBar.window = $0 }
        .background(Theme.bg0)
        .background(WindowChrome())
        .toolbar {
            // 버튼마다 툴바 항목이 따로 생기게 묶음으로 둔다(항목마다 손쉬운 사용 이름이 붙는다).
            ToolbarItemGroup(placement: .navigation) {
                TitleLeading(widths: titleBar)
            }
            .jPlainToolbarItem()
            ToolbarItem(placement: .principal) {
                AIGroup(widths: titleBar)
            }
            .jPlainToolbarItem()
            ToolbarItemGroup(placement: .primaryAction) {
                TitleTrailing(widths: titleBar, onExport: onExport)
            }
            .jPlainToolbarItem()
        }
        .toolbarBackground(Theme.bg0, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    static let titleBarHeight: CGFloat = 52

    /// 사이드바 | 영상 | 인스펙터.
    private var columns: some View {
        JSplitView(axis: .horizontal, panes: [
            .init(minimum: 200, initial: 232, content: pane(
                Sidebar())),
            .init(minimum: 400, initial: nil, content: pane(
                VStack(spacing: 0) {
                    PlayerPane().frame(maxWidth: .infinity, maxHeight: .infinity)
                    Transport()
                }
                .background(Theme.bg0))),
            .init(minimum: 280, initial: 336, content: pane(InspectorPane()),
                  collapsed: model.inspectorCollapsed),
        ], onCollapse: { index, collapsed in
            // 인스펙터를 끌어 접거나 폈다.
            if index == 2, model.inspectorCollapsed != collapsed { model.inspectorCollapsed = collapsed }
        })
    }

    /// 타임라인 칸: 도구 막대, 트랙 머리, 타임라인.
    private var timelineColumn: some View {
        TimelinePanel(onImport: onImport, onDrop: onDrop)
    }

    /// 분할 칸은 따로 NSHostingView에 담기니 모델을 다시 넣어 준다.
    private func pane(_ content: some View) -> AnyView {
        AnyView(content.environment(model).environment(generation))
    }
}

/// 제목 막대 폭. 창과 양쪽 항목의 폭을 재서 가운데(AI 묶음) 자리를 셈한다.
/// 툴바 항목은 단추마다 따로라 묶음 전체를 잴 수 없다. 폭이 바뀌는 항목만 재고 나머지는 고정 폭으로 셈한다.
@MainActor @Observable
final class TitleBarWidths {
    var window: CGFloat = 0
    /// 프로젝트 이름과 길이 줄.
    var name: CGFloat = 0
    /// "작품 노트"와 "내보내기".
    var notes: CGFloat = 0
    var export: CGFloat = 0

    /// 왼쪽에서 이름 말고 차지하는 폭: 신호등 단추·여백(92), 목록 단추 항목(44), 항목 여백.
    static let leadingFixed: CGFloat = 92 + 44 + 10
    /// 오른쪽에서 단추 말고 차지하는 폭: 구분선 항목과 항목 사이(44), 항목 여백, 오른쪽 여백.
    static let trailingFixed: CGFloat = 44 + 16 + 4
    /// 가운데 폭이 이보다 좁으면 AI 묶음의 "AI" 표시와 아이콘을 숨긴다("번역 검토 ▾"만큼 넓혔다).
    static let compactAIWidth: CGFloat = 500

    /// 가운데 칸의 폭. 시안처럼 가운데 칸은 양쪽 중 넓은 쪽만큼 비켜 둔다(1fr auto 1fr).
    var center: CGFloat {
        let leading = Self.leadingFixed + name
        let trailing = Self.trailingFixed + notes + export
        return window - 2 * max(leading, trailing)
    }
}

/// 제목 막대 가운데 AI 묶음(시안 1 .ai-group): [자동 자막 생성] [원문 검토] [지시 검토] [번역 ▾] [번역 검토 ▾].
/// 비활성 조건과 도움말: 작업 중이면 모두 막고, LLM이 없으면 검토·번역을 막고 설정 안내를 보인다.
/// 진행과 [취소]는 상태 표시줄과 사이드바 진행 기록에 보인다.
private struct AIGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    /// LLM 설정이 바뀌면 비활성·도움말을 다시 정하게 지켜본다.
    @AppStorage(LLMEnvironment.defaultsKey) private var llmSettingsData: Data?
    let widths: TitleBarWidths
    @State private var translateAnchor = JMenuAnchor.Anchor()
    @State private var reviewAnchor = JMenuAnchor.Anchor()

    private static let style = JButtonStyle(role: .ghost, height: 26)

    var body: some View {
        let compact = widths.window > 0 && widths.center < TitleBarWidths.compactAIWidth
        let llmReady = LLMEnvironment.isTextReady(LLMSettings.decode(llmSettingsData))
        HStack(spacing: 4) {
            if !compact {
                Text("AI")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.2)
                    .foregroundStyle(Theme.text3)
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
            }
            Button { generation.openGenerationSheet(model: model) } label: {
                Label("자동 자막 생성", systemImage: "sparkles").labelStyle(AILabelStyle(compact: compact))
            }
            .disabled(generation.isRunning || model.mediaURL == nil || model.currentSet == nil)
            .help("영상에서 지금 자막셋의 자막을 만들어요")
            Button { generation.startReview(model: model, kind: .source, targets: nil) } label: {
                Label("원문 검토", systemImage: "checkmark.circle").labelStyle(AILabelStyle(compact: compact))
            }
            .disabled(generation.isRunning || !llmReady || !GenerationController.canRunLLM(model))
            .help(llmReady ? "지금 자막셋의 작품 원어를 검토해 고칠 곳을 티켓으로 만들어요" : GenerationController.llmSetupNote)
            Button { generation.openInstructionReview(model: model) } label: {
                Label("지시 검토", systemImage: "text.bubble").labelStyle(AILabelStyle(compact: compact))
            }
            .disabled(generation.isRunning || !llmReady || model.currentSet == nil)
            .help(llmReady ? "지시를 써서 지금 자막셋을 검토해요. 지시에 맞는 곳만 티켓으로 받아요" : GenerationController.llmSetupNote)
            Button { translateAnchor.popUp(translateMenu) } label: {
                HStack(spacing: 4) {
                    Text("번역")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .background(JMenuAnchor(anchor: translateAnchor))
            .disabled(generation.isRunning || !llmReady || !GenerationController.canTranslate(model))
            .help(llmReady ? "조각 안의 한 언어 문장을 다른 언어 칸으로 옮겨요" : GenerationController.llmSetupNote)
            .accessibilityLabel("번역")
            let reviewLanguages = GenerationController.reviewLanguages(model)
            Button { reviewAnchor.popUp(reviewMenu(reviewLanguages)) } label: {
                HStack(spacing: 4) {
                    Text("번역 검토")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .background(JMenuAnchor(anchor: reviewAnchor))
            .disabled(generation.isRunning || !llmReady || reviewLanguages.isEmpty)
            .help(!llmReady ? GenerationController.llmSetupNote
                  : reviewLanguages.isEmpty ? "번역한 언어가 있으면 검토할 수 있어요"
                  : "번역을 원문과 견줘 검토하고 고칠 곳을 티켓으로 만들어요")
            .accessibilityLabel("번역 검토")
        }
        .buttonStyle(Self.style)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI")
    }

    /// "번역 ▾": 번역할 언어를 골라 번역 시트를 연다(작품 원어 말고, 자막셋에 없는 언어는 시트가 더한다).
    private var translateMenu: [JMenuEntry] {
        guard model.currentSet != nil, let original = model.originalLanguage else { return [] }
        return Language.allCases.filter { $0 != original }.map { language in
            JMenuEntry(title: "\(language.displayName)로 번역…") {
                generation.openTranslationSheet(model: model, target: language)
            }
        }
    }
}

extension AIGroup {
    /// "번역 검토 ▾": 번역이 있는 언어마다 그 언어의 번역 검토(자막셋 전체).
    fileprivate func reviewMenu(_ languages: [Language]) -> [JMenuEntry] {
        languages.map { language in
            JMenuEntry(title: GenerationController.reviewTitle(.translation(language))) {
                generation.startReview(model: model, kind: .translation(language), targets: nil)
            }
        }
    }
}

/// 좁을 때는 아이콘을 숨기고 글자만 보인다.
private struct AILabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            if !compact { configuration.icon.font(.system(size: 11)) }
            configuration.title
        }
    }
}

/// 제목 막대 왼쪽: 프로젝트 목록 버튼, 프로젝트 이름, `길이 · 해상도 · fps`.
private struct TitleLeading: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    let widths: TitleBarWidths

    var body: some View {
        Group {
            Button { model.requestCloseProject() } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.jIcon)
            .help("프로젝트 목록")
            .accessibilityLabel("프로젝트 목록")
            .disabled(generation.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.project?.name ?? "Jamak")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .truncationMode(.tail)
                    .help("\(model.project?.name ?? "") · 더블클릭해서 이름 바꾸기")
                    .onTapGesture(count: 2) { model.renamingProject = model.project?.summary }
                    .accessibilityAction(named: "이름 바꾸기") { model.renamingProject = model.project?.summary }
                Text(meta)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
            }
            .lineLimit(1)
            // 긴 이름은 뒤를 줄여 툴바 항목이 넘침 메뉴로 밀려나지 않게 한다.
            .frame(maxWidth: 260, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.name = $0 }
        }
    }

    /// 예: "1:58:42 · 1920×1080 · 23.976fps". 해상도와 fps를 모르면 길이만.
    private var meta: String {
        let duration = Timecode.short(model.durationMs)
        guard let info = model.videoInfo?.label, !info.isEmpty else { return duration }
        return "\(duration) · \(info)"
    }
}

/// 제목 막대 오른쪽: "작품 노트"(인스펙터 탭 전환), 구분선, "내보내기".
private struct TitleTrailing: View {
    @Environment(AppModel.self) private var model
    let widths: TitleBarWidths
    let onExport: () -> Void

    var body: some View {
        Group {
            Button { model.toggleNotesTab() } label: {
                Label("작품 노트", systemImage: "note.text").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jGhost(isOn: model.inspectorTab == .notes && !model.inspectorCollapsed))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.notes = $0 }
            Rectangle().fill(Theme.line2).frame(width: 1, height: 18).padding(.horizontal, 4)
            Button(action: onExport) {
                Label("내보내기", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.jPrimary)
            .disabled(model.languages.isEmpty)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.export = $0 }
        }
    }
}

/// 창 바탕을 bg0으로 하고 시스템 제목 글자와 제목 막대 구분선을 끈다(구분선은 `EditorShell`이 `line`으로 그린다).
struct WindowChrome: NSViewRepresentable {
    final class Probe: NSView {
        /// 창 안에 있는 Probe 수. 목록 ↔ 편집 화면 전환 때 새 Probe가 먼저 들어와도 되돌리기가 덮어쓰지 않게 센다.
        private static var live = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Self.live += 1
            window.backgroundColor = Theme.NS.bg0
            window.titlebarSeparatorStyle = .none
            // 프로젝트 이름은 제목 막대 왼쪽 항목이 보여 준다.
            window.titleVisibility = .hidden
        }

        /// 이 화면을 떠나 다른 Probe도 없으면(영상 찾기 화면) 제목 글자와 구분선을 되돌린다.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window {
                Self.live -= 1
                if Self.live == 0 {
                    window.titleVisibility = .visible
                    window.titlebarSeparatorStyle = .automatic
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

extension ToolbarContent {
    /// 툴바 항목을 감싸는 시스템 배경(macOS 26의 유리 묶음)을 끈다. 모양은 Theme 스타일이 맡는다.
    @ToolbarContentBuilder func jPlainToolbarItem() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
