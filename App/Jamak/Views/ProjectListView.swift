import AppKit
import JamakCore
import SwiftUI
import UniformTypeIdentifiers

/// 첫 화면(설계 문서 4절). 제목 막대(앱 이름·프로젝트 수·검색·"영상 열기"), 왼쪽 필터, 끌어다 놓기 영역, 포스터 카드 격자.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var isDropTargeted = false
    @State private var filter = ProjectFilter.recent
    @State private var query = ""
    @State private var pendingDelete: ProjectSummary?
    @State private var pendingRename: ProjectSummary?

    /// 생성·영상 열기·MKV 변환 중에는 열기와 삭제를 막는다(메뉴 "영상 열기…"와 같은 기준).
    private var isBusy: Bool {
        generation.isRunning || model.isOpeningVideo || model.conversionProgress != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 1)
            main
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Theme.bg0)
        .background(WindowChrome())
        .task { await model.reloadProjects() }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Jamak").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("프로젝트 \(model.projects.count)개")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                }
                .padding(.leading, 6)
            }
            .jPlainToolbarItem()
            ToolbarItemGroup(placement: .primaryAction) {
                SearchField(text: $query)
                Button { model.chooseVideoAndOpen() } label: {
                    Label("영상 열기", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.jPrimary)
                .disabled(isBusy)
            }
            .jPlainToolbarItem()
        }
        .toolbarBackground(Theme.bg0, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .projectRenameAlert(target: $pendingRename) { summary, name in
            Task { await model.renameProject(summary, to: name) }
        }
        .confirmationDialog(
            "\(pendingDelete?.name ?? "") 프로젝트를 휴지통으로 옮길까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { summary in
            Button("휴지통으로 옮기기", role: .destructive) { Task { await model.deleteProject(summary) } }
            Button("취소", role: .cancel) {}
        } message: { summary in
            if summary.format == .corrupt {
                Text("프로젝트 파일을 읽을 수 없는 프로젝트예요. 자막(subtitles.json)을 포함한 폴더 전체가 휴지통으로 옮겨져요. 원본 영상은 그대로 남아요.")
            } else {
                Text("원본 영상은 그대로 남아요.")
            }
        }
    }

    // MARK: 필터

    private func count(_ filter: ProjectFilter) -> Int {
        model.projects.filter { filter.includes($0) }.count
    }

    private static func title(_ filter: ProjectFilter) -> String {
        switch filter {
        case .recent: "최근 프로젝트"
        case .needsReview: "검토할 곳이 있음"
        case .resumable: "이어서 할 작업"
        }
    }

    private static func icon(_ filter: ProjectFilter) -> String {
        switch filter {
        case .recent: "film"
        case .needsReview: "sparkles"
        case .resumable: "arrow.counterclockwise"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ProjectFilter.allCases, id: \.self) { item in
                FilterRow(title: Self.title(item), icon: Self.icon(item), count: count(item), isOn: filter == item) {
                    filter = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Theme.bg1)
    }

    private var shown: [ProjectSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.projects.filter { filter.includes($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
    }

    // MARK: 본문

    private var main: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dropArea
                if model.projects.isEmpty {
                    Text("아직 프로젝트가 없어요.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.title(filter)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        if filter == .recent {
                            Text("마지막으로 연 순서").font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                    let items = shown
                    if items.isEmpty {
                        Text("조건에 맞는 프로젝트가 없어요.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(items, id: \.folder) { summary in
                                ProjectCard(summary: summary, isBusy: isBusy,
                                            open: { Task { await model.open(summary) } },
                                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([summary.folder]) },
                                            rename: { pendingRename = summary },
                                            delete: { if summary.format != .newer { pendingDelete = summary } })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg0)
    }

    private var dropArea: some View {
        HStack(spacing: 18) {
            Image(systemName: "film")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("영상을 끌어다 놓아 새 프로젝트를 만드세요")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("mp4, mov, mkv. MKV는 열 때 mp4로 바꿔요. 원본 영상은 옮기지 않아요.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 12)
            Button("파일 고르기") { model.chooseVideoAndOpen() }
                .buttonStyle(.jSecondary)
                .disabled(isBusy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            LinearGradient(colors: [Color.white.opacity(0.015), .clear], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isDropTargeted ? Theme.accent : Theme.line2)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isBusy, let url = urls.first else { return false }
            Task { await model.perform { try await model.openVideo(url) } }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

/// 왼쪽 필터 한 줄(시안 .pnav).
private struct FilterRow: View {
    let title: String
    let icon: String
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
                Text("\(count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            .foregroundStyle(isOn || isHovering ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isOn ? Theme.bg3 : isHovering ? Theme.bg2 : .clear, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 제목 막대의 검색 입력(시안 .input, 폭 220).
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.text3)
            TextField("프로젝트 찾기", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .accessibilityLabel("프로젝트 찾기")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    .help("지우기")
                    .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 220, height: 28)
        .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1) }
    }
}

/// MKV를 mp4로 바꾸는 동안 창 위에 덮는 진행률 패널. 닫힘은 변환이 끝나면 모델이 정하고, 사용자는 "취소"로만 멈춘다.
struct ConversionOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            // 아래 화면을 가리고 클릭을 막는다.
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 14) {
                Text("MKV를 mp4로 변환하는 중이에요")
                    .font(.headline)
                ProgressView(value: model.conversionProgress ?? 0)
                HStack {
                    Spacer()
                    Button("취소") { model.cancelConversion() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12)
        }
    }
}

/// `NSOpenPanel`로 파일을 고른다.
@MainActor
enum FilePicker {
    static func chooseVideo(includeMKV: Bool) -> URL? {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if includeMKV, let mkv = UTType(filenameExtension: "mkv") { types.append(mkv) }
        return choose(types)
    }

    static func chooseSRT() -> URL? {
        choose([UTType(filenameExtension: "srt") ?? .plainText])
    }

    /// 내보낼 폴더. `startingAt`이 있으면 그 폴더에서 연다.
    static func chooseFolder(startingAt folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.directoryURL = folder
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 자막을 넣은 영상을 저장할 위치. 파일 이름의 기본값은 `name`. 덮어쓰기 확인은 패널이 한다.
    static func chooseSaveLocation(name: String, container: SubtitleContainer, startingAt folder: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.prompt = "내보내기"
        if let type = container == .mkv ? UTType(filenameExtension: "mkv") : .mpeg4Movie {
            panel.allowedContentTypes = [type]
        }
        panel.directoryURL = folder
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func choose(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 새 프로젝트: "이 영상의 원문 언어"(한국어·일본어·영어). 설정의 원문 언어가 그중 하나면 미리 고른다.
/// 취소하면 프로젝트를 만들지 않는다.
struct SourceLanguageSheet: View {
    let question: AppModel.LanguageQuestion
    let onAnswer: (Language?) -> Void
    @State private var selection: Language?

    init(question: AppModel.LanguageQuestion, onAnswer: @escaping (Language?) -> Void) {
        self.question = question
        self.onAnswer = onAnswer
        _selection = State(initialValue: question.preselected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이 영상의 원문 언어").font(.headline)
            Text(question.videoName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("원문 언어", selection: $selection) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(Optional(language))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("취소", role: .cancel) { onAnswer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("만들기") { onAnswer(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

enum LanguageName {
    /// 예: "한국어". 알 수 없는 코드는 코드 그대로.
    static func name(_ code: String) -> String {
        Locale(identifier: "ko_KR").localizedString(forIdentifier: code) ?? code
    }

    /// 예: "한국어 (ko)". 알 수 없는 코드는 코드 그대로.
    static func label(_ code: String) -> String {
        guard let name = Locale(identifier: "ko_KR").localizedString(forIdentifier: code) else { return code }
        return "\(name) (\(code))"
    }
}

/// 프로젝트 이름 바꾸기 창. 목록 카드와 편집 화면 제목 막대가 함께 쓴다.
private struct ProjectRenameAlert: ViewModifier {
    @Binding var target: ProjectSummary?
    let commit: (ProjectSummary, String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("프로젝트 이름 바꾸기", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                   presenting: target) { summary in
                TextField("이름", text: $text)
                Button("바꾸기") { commit(summary, text) }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("비우면 영상 이름으로 돌아가요. 프로젝트 폴더 이름은 바뀌지 않아요.")
            }
            .onChange(of: target?.folder) { text = target?.name ?? "" }
    }
}

extension View {
    /// `target`이 있으면 이름 바꾸기 창을 띄운다. "바꾸기"를 누르면 `commit(프로젝트, 새 이름)`.
    func projectRenameAlert(target: Binding<ProjectSummary?>, commit: @escaping (ProjectSummary, String) -> Void) -> some View {
        modifier(ProjectRenameAlert(target: target, commit: commit))
    }
}
