import AppKit
import JamakCore
import SwiftUI

/// 편집기: 배치는 `EditorShell`이 맡고, 여기서는 가져오기·내보내기 시트와 확인 대화상자를 붙인다.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @State private var pendingImport: PendingImport?
    /// 가져오기 시트에서 고른 srt와 언어. 시트가 닫힌 뒤 확인 질문을 거쳐 가져온다.
    @State private var chosenImport: (url: URL, language: Language)?
    /// 확인을 기다리는 가져오기. 언어 추가 → 덮어쓰기 순으로 묻는다.
    @State private var addLanguageImport: AppModel.SRTImportPlan?
    @State private var overwriteImport: AppModel.SRTImportPlan?
    @State private var showExport = false
    /// 내보내기 시트에서 고른 언어. 시트가 닫힌 뒤 폴더를 묻는다.
    @State private var exportChoice: ExportChoice?
    @State private var overwrite: ExportRequest?
    @State private var exported: [URL]?
    @State private var keyMonitor = EditorKeyMonitor()

    /// 배치. 시트와 대화상자는 `body`에서 붙인다.
    private var shell: some View {
        EditorShell(onImport: { chooseSRT() }, onExport: { showExport = true }, onDrop: { acceptDrop($0) })
            // 창 제목(창 메뉴, 손쉬운 사용). 제목 막대에는 보이지 않는다.
            .navigationTitle(model.project?.name ?? "Jamak")
    }

    var body: some View {
        @Bindable var model = model
        shell
        .onAppear { keyMonitor.start(model: model) }
        // 제목 막대의 프로젝트 이름을 더블클릭했다.
        .projectRenameAlert(target: $model.renamingProject) { _, name in
            Task { await model.renameCurrentProject(to: name) }
        }
        // 파일 메뉴 "srt 가져오기…".
        .onChange(of: model.srtImportRequested) { _, requested in
            guard requested else { return }
            model.srtImportRequested = false
            chooseSRT()
        }
        .onDisappear { keyMonitor.stop() }
        .sheet(isPresented: $showExport, onDismiss: chooseExportFolder) {
            ExportSheet(original: model.originalLanguage ?? .ko,
                        videoBlocked: generation.isRunning) { choice in
                exportChoice = choice
                showExport = false
            } onCancel: { showExport = false }
        }
        .alert("\(overwrite?.count ?? 0)개 파일을 덮어쓸까요?", isPresented: isPresent($overwrite), presenting: overwrite) { request in
            Button("덮어쓰기", role: .destructive) { writeExport(request) }
            Button("취소", role: .cancel) {}
        }
        .alert("내보냈어요", isPresented: isPresent($exported), presenting: exported) { urls in
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            Button("확인", role: .cancel) {}
        } message: { urls in
            Text(urls.map(\.lastPathComponent).joined(separator: "\n"))
        }
        .alert("내보냈어요", isPresented: exportedVideoShown, presenting: generation.exportedVideo) { url in
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                generation.dismissExported()
            }
            Button("확인", role: .cancel) { generation.dismissExported() }
        } message: { url in
            Text(url.lastPathComponent)
        }
        .sheet(item: $pendingImport, onDismiss: proceedImport) { item in
            ImportSheet(item: item, original: model.originalLanguage ?? .ko,
                        blocked: importBlockedNote != nil) { language in
                chosenImport = (item.url, language)
                pendingImport = nil
            } onCancel: { pendingImport = nil }
        }
        // 자동 자막 생성·번역 시트(시안 3). 시트는 따로 창에 그려지니 모델을 다시 넣어 준다.
        .sheet(item: generationSheet) { request in
            GenerationSheet(request: request).environment(model).environment(generation)
        }
        .sheet(item: translationSheet) { request in
            TranslationSheet(request: request).environment(model).environment(generation)
        }
        .sheet(item: instructionSheet) { request in
            InstructionReviewSheet(request: request, lastInstruction: generation.lastInstruction)
                .environment(model).environment(generation)
        }
        .alert("번역을 마쳤어요", isPresented: finishedTranslationShown,
               presenting: generation.finishedTranslation) { language in
            // 번역은 같은 조각의 그 언어 칸에 들어갔다. 그 언어를 출력 언어로 보인다.
            Button("\(language.displayName) 보기") {
                generation.dismissFinishedTranslation()
                if model.currentSet?.languages.contains(language) == true { model.setOutputLanguage(.one(language)) }
            }
            Button("확인", role: .cancel) { generation.dismissFinishedTranslation() }
        } message: { language in
            Text((["\(language.displayName) 칸을 번역했어요."] + generation.finishedTranslationNotes)
                .joined(separator: "\n\n"))
        }
        .alert(GenerationController.notesRewriteQuestion, isPresented: notesRewriteShown) {
            Button("새로 쓰기", role: .destructive) { generation.rewriteNotes(model: model) }
            Button("취소", role: .cancel) { generation.asksNotesRewrite = false }
        } message: {
            Text(GenerationController.notesRewriteNote)
        }
        .alert(generation.clearQuestion?.foundSpeech == true ? RangeActions.replaceDroppingQuestion : RangeActions.clearQuestion,
               isPresented: clearRangeShown, presenting: generation.clearQuestion) { _ in
            Button("지우기", role: .destructive) { generation.answerClear(true) }
            Button("취소", role: .cancel) { generation.answerClear(false) }
        } message: { question in
            if question.losesTranslations { Text(RangeActions.clearLosesTranslationsNote) }
        }
        .alert("자막셋에 \(addLanguageImport?.language.displayName ?? "")를 추가할까요?",
               isPresented: isPresent($addLanguageImport), presenting: addLanguageImport) { plan in
            Button("추가") { confirmOverwrite(plan) }
            Button("취소", role: .cancel) {}
        }
        .alert("\(overwriteImport?.overwrites ?? 0)개 조각의 \(overwriteImport?.language.displayName ?? "") 문장을 덮어쓸까요?",
               isPresented: isPresent($overwriteImport), presenting: overwriteImport) { plan in
            Button("덮어쓰기", role: .destructive) { runImport(plan) }
            Button("취소", role: .cancel) {}
        }
    }

    /// 끌어다 놓은 srt를 가져오기 시트로 넘긴다. 가져올 수 없는 작업 중이면 알리고 받지 않는다.
    private func acceptDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == "srt" }) else { return false }
        guard importAllowed() else { return false }
        pendingImport = PendingImport(url: url)
        return true
    }

    /// 가져오기 시트가 닫힌 뒤: 계획을 세워 언어가 없으면 추가할지, 덮어쓰게 되면 덮어쓸지 차례로 묻는다.
    /// 취소하면 아무것도 바꾸지 않는다.
    private func proceedImport() {
        guard let request = chosenImport else { return }
        chosenImport = nil
        guard importAllowed() else { return }
        do {
            let plan = try model.planSRTImport(request.url, language: request.language)
            if plan.addsLanguage { addLanguageImport = plan } else { confirmOverwrite(plan) }
        } catch { model.report(error) }
    }

    private func confirmOverwrite(_ plan: AppModel.SRTImportPlan) {
        if plan.overwrites > 0 { overwriteImport = plan } else { runImport(plan) }
    }

    /// 한 번의 실행 취소 단계로 가져온다(없는 언어를 더하는 것까지). 저장하지 않는다.
    private func runImport(_ plan: AppModel.SRTImportPlan) {
        guard importAllowed() else { return }
        do { try model.importSRT(plan) } catch { model.report(error) }
    }

    /// 작업 중에는 자막을 가져오지 않는다(결과를 넣을 편집기나 읽는 자막셋이 바뀐다). 영상 내보내기도 막는다.
    private var importBlockedNote: String? {
        generation.importBlockedNote ?? (model.isJobRunning || generation.isRunning ? "작업 중에는 자막을 가져올 수 없어요" : nil)
    }

    private func importAllowed() -> Bool {
        guard let note = importBlockedNote else { return true }
        model.alertMessage = note
        return false
    }

    private func chooseExportFolder() {
        guard let choice = exportChoice else { return }
        exportChoice = nil
        let languages = choice.languages, fallback = choice.fallback
        if case .video(let container) = choice.format {
            exportVideo(languages: languages, fallback: fallback, container: container)
            return
        }
        guard let folder = FilePicker.chooseFolder(startingAt: model.videoURL?.deletingLastPathComponent()) else { return }
        let request = ExportRequest(folder: folder, languages: languages, fallback: fallback,
                                    count: model.exportConflicts(languages: languages, in: folder).count)
        if request.count > 0 { overwrite = request } else { writeExport(request) }
    }

    /// 저장 위치를 묻고 자막을 넣은 영상 만들기를 시작한다.
    private func exportVideo(languages: [Language], fallback: Bool, container: SubtitleContainer) {
        guard !generation.isRunning else { return }
        guard let input = model.exportInputVideo(for: container) else {
            model.alertMessage = "내보낼 영상을 찾을 수 없어요"
            return
        }
        let name = VideoExport.defaultFileName(videoName: model.exportVideoName, container: container)
        guard let output = FilePicker.chooseSaveLocation(
            name: name, container: container, startingAt: model.videoURL?.deletingLastPathComponent())
        else { return }
        generation.exportVideo(tracks: model.exportTracks(languages: languages, fallback: fallback), container: container, input: input,
                               durationMs: model.durationMs, output: output, model: model)
    }

    private var exportedVideoShown: Binding<Bool> {
        Binding(get: { generation.exportedVideo != nil }, set: { if !$0 { generation.dismissExported() } })
    }

    private func writeExport(_ request: ExportRequest) {
        do {
            exported = try model.export(languages: request.languages, fallback: request.fallback, to: request.folder)
        } catch {
            model.report(error)
        }
    }

    private var generationSheet: Binding<GenerationController.GenerationSheetRequest?> {
        Binding(get: { generation.generationSheet }, set: { generation.generationSheet = $0 })
    }

    private var instructionSheet: Binding<GenerationController.InstructionReviewRequest?> {
        Binding(get: { generation.instructionSheet }, set: { generation.instructionSheet = $0 })
    }

    private var translationSheet: Binding<GenerationController.TranslationSheetRequest?> {
        Binding(get: { generation.translationSheet }, set: { generation.translationSheet = $0 })
    }

    private var finishedTranslationShown: Binding<Bool> {
        Binding(get: { generation.finishedTranslation != nil },
                set: { if !$0 { generation.dismissFinishedTranslation() } })
    }

    private var notesRewriteShown: Binding<Bool> {
        Binding(get: { generation.asksNotesRewrite }, set: { if !$0 { generation.asksNotesRewrite = false } })
    }

    private var clearRangeShown: Binding<Bool> {
        // 닫힘은 버튼이 처리한다(답을 기다리는 구간 작업이 있다).
        Binding(get: { generation.clearQuestion != nil }, set: { _ in })
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func chooseSRT() {
        guard importAllowed(), let url = FilePicker.chooseSRT() else { return }
        pendingImport = PendingImport(url: url)
    }
}

/// 편집기 창의 Space(재생/정지), ⌫(선택 조각 삭제), Esc(구간 선택 해제), ←/→(5초 앞뒤), ,/.(한 프레임 앞뒤),
/// Shift+,/Shift+.(재생 속도 한 단계 내리기·올리기).
/// 글을 고치는 중이거나 시트가 떠 있으면 건드리지 않는다.
@MainActor
final class EditorKeyMonitor {
    private var token: Any?
    /// ←/→로 옮기는 시간.
    private static let seekStepMs = 5_000

    func start(model: AppModel) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { Self.handle(event, model: model) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = event.window, !(window is NSPanel),
              window.attachedSheet == nil, window.sheetParent == nil,
              !(window.firstResponder is NSText)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .shift {
            switch event.keyCode {
            case 43:   // Shift+, (재생 속도 내리기)
                model.stepPlaybackRate(-1)
                return true
            case 47:   // Shift+. (재생 속도 올리기)
                model.stepPlaybackRate(1)
                return true
            default:
                return false
            }
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49:   // Space
            model.togglePlay()
            return true
        case 51, 117:   // Delete, Forward Delete
            guard model.selectedCueID != nil || model.selectedMemoID != nil, !model.isActiveSetLocked else { return false }
            model.deleteSelected()
            return true
        case 53:   // Escape
            guard model.selectedRange != nil else { return false }
            model.selectedRange = nil
            return true
        case 123:   // ←
            model.seek(byMs: -seekStepMs)
            return true
        case 124:   // →
            model.seek(byMs: seekStepMs)
            return true
        case 43:   // , (한 프레임 뒤로)
            model.stepFrame(-1)
            return true
        case 47:   // . (한 프레임 앞으로)
            model.stepFrame(1)
            return true
        default:
            return false
        }
    }
}

/// 영상을 찾지 못했을 때 편집기 대신 보여 주는 화면.
struct MissingVideoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Text("영상을 찾을 수 없어요. 원래 영상을 다시 지정해 주세요.")
                .font(.title3)
            if let path = model.project?.state.videoPath {
                Text(path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("프로젝트 목록") { model.closeProject() }
                Button("영상 찾기") {
                    guard let url = FilePicker.chooseVideo(includeMKV: false) else { return }
                    Task { await model.perform { try await model.relinkVideo(url) } }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(model.project?.name ?? "Jamak")
    }
}
