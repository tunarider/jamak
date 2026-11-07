import AppKit
import JamakCore
import SwiftUI

@main
struct JamakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Jamak", id: "main") {
            RootView()
                .environment(appDelegate.model)
                .environment(appDelegate.generation)
        }
        .commands { EditorCommands(model: appDelegate.model, generation: appDelegate.generation) }
        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.generation)
        }
    }
}

/// 앱 종료 전에 도는 작업(생성, 내보내기, 구간 작업, MKV 변환) 중단 확인과 저장 확인을 거친다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let generation = GenerationController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 앱 전체 외관은 어둡게 고정한다.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GenerationController.sweepStaleExports()
    }

    /// 창이 하나뿐이니 창을 닫으면 앱을 끝낸다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 노트 패널에 쓰던 내용은 묻지 않고 저장한다.
        model.notes.flush()
        // 토큰 사용량도 묻지 않고 저장한다(작업을 멈추면 멈춘 뒤에 한 번 더 저장한다).
        model.saveTokenUsage()
        guard let message = runningJobMessage else { return confirmSaving(sender) }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // 작업을 멈추고 ffmpeg 종료·임시 파일 삭제·진행 저장이 끝난 뒤에 끝낸다(생성은 다음에 이어서 한다).
        Task {
            await generation.cancelAndWait()
            await model.cancelConversionAndWait()
            model.saveTokenUsage()
            switch confirmSaving(sender) {
            case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
            case .terminateCancel: sender.reply(toApplicationShouldTerminate: false)
            default: break   // 저장 확인이 답한다.
            }
        }
        return .terminateLater
    }

    /// 도는 작업이 있으면 종료할 때 물을 문구.
    private var runningJobMessage: String? {
        if model.isConverting { return "MKV를 변환하는 중이에요. 종료하면 변환이 취소돼요." }
        guard generation.isRunning else { return nil }
        return (generation.jobKind ?? .generation).quitMessage
    }

    /// 저장 안 된 변경이 있으면 저장 확인을 거친다. `.terminateLater`면 확인이 직접 답한다.
    private func confirmSaving(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.flushDraft()
        guard model.isDirty else { return .terminateNow }
        // 편집기 창이 보이고 그 위에 다른 시트·경고가 없을 때만 창에 붙은 확인을 쓴다.
        // 그 밖(창이 없거나 내보내기 시트 같은 것이 떠 있음)에는 SwiftUI 확인이 뜨지 못할 수 있으니 따로 묻는다.
        let mainWindow = sender.windows.first {
            $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil && !($0 is NSPanel)
        }
        guard let mainWindow, mainWindow.attachedSheet == nil, model.pendingAction == nil else {
            return askModally()
        }
        model.confirmDiscardingChanges {
            sender.reply(toApplicationShouldTerminate: true)
        } onCancel: {
            sender.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }

    private func askModally() -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "저장하지 않은 변경이 있어요"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "저장 안 함")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try model.save()
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failure.addButton(withTitle: "확인")
                failure.runModal()
                return .terminateCancel
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

/// 메뉴 명령: 영상 열기, 저장, 실행 취소/복귀, 줌, 검토(티켓 이동·반영·미반영).
struct EditorCommands: Commands {
    let model: AppModel
    let generation: GenerationController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("영상 열기…") { model.chooseVideoAndOpen() }
                .keyboardShortcut("o")
                .disabled(generation.isRunning || model.conversionProgress != nil)
            Button("srt 가져오기…") { model.srtImportRequested = true }
                .disabled(model.editor == nil || model.isJobRunning || generation.isRunning)
        }
        CommandGroup(replacing: .saveItem) {
            // 창이 하나뿐이라 닫기는 종료와 같다(저장 확인을 거친다).
            Button("닫기") { NSApp.terminate(nil) }
                .keyboardShortcut("w")
            Button("저장") { model.saveReportingErrors() }
                .keyboardShortcut("s")
                .disabled(model.editor == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("실행 취소") { Self.undo(model) }
                .keyboardShortcut("z")
            Button("실행 복귀") { Self.redo(model) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("확대") { model.zoom(by: 1.5) }
                .keyboardShortcut("=")
                .disabled(model.editor == nil)
            Button("축소") { model.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-")
                .disabled(model.editor == nil)
        }
        CommandMenu("검토") {
            Button("다음 티켓") { model.selectNextTicket() }
                .keyboardShortcut("g")
                .disabled(model.visibleTickets.isEmpty)
            Button("이전 티켓") { model.selectPreviousTicket() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.visibleTickets.isEmpty)
            Button("티켓 \(TicketAction.primaryTitle(of: model.selectedTicket, model: model))") {
                Self.ticketKey(text: { model.flushDraft() }) {
                    guard let ticket = model.selectedTicket else { return }
                    TicketAction.performPrimary(ticket, model: model, generation: generation)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canProcessSelectedTicket)
            Button("티켓 \(TicketAction.secondaryTitle(of: model.selectedTicket, original: model.originalLanguage))") {
                Self.ticketKey(text: {
                    NSApp.sendAction(Selector(("deleteToBeginningOfLine:")), to: nil, from: nil)
                }) {
                    guard let ticket = model.selectedTicket else { return }
                    model.rejectTicket(ticket.id)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!model.canProcessSelectedTicket)
            #if DEBUG
            Button("티켓 예시 넣기") { model.insertSampleTickets() }
                .disabled(model.currentSet == nil || model.isActiveSetLocked)
            #endif
            Divider()
            Button(GenerationController.reviewTitle(.source)) {
                generation.startReview(model: model, kind: .source, targets: nil)
            }
            .disabled(generation.isRunning || model.project == nil || !GenerationController.canRunLLM(model))
            Menu("번역 검토") {
                ForEach(GenerationController.reviewLanguages(model), id: \.self) { language in
                    Button(GenerationController.reviewTitle(.translation(language))) {
                        generation.startReview(model: model, kind: .translation(language), targets: nil)
                    }
                }
            }
            .disabled(generation.isRunning || model.project == nil || GenerationController.reviewLanguages(model).isEmpty)
            Button("\(GenerationController.instructionTitle)…") { generation.openInstructionReview(model: model) }
                .disabled(generation.isRunning || model.currentSet == nil)
            Button("노트 새로 쓰기…") { generation.requestNotesRewrite(model: model) }
                .disabled(generation.isRunning || model.project == nil || !GenerationController.canRunLLM(model))
        }
    }

    /// 글을 고치는 중이고 그 글에 되돌릴 입력이 남아 있으면 그 글의 실행 취소, 아니면 자막 편집의 실행 취소.
    /// 커밋한 칸의 입력 기록은 커밋할 때 지우니(`AppModel.bodyDraft`), 다른 칸에서 누른 ⌘Z가 그 칸의 글을
    /// 되돌리지 않고 자막 편집을 되돌린다.
    private static func undo(_ model: AppModel) {
        if isComposing() { return }
        if let text = NSApp.keyWindow?.firstResponder as? NSText, text.undoManager?.canUndo == true {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
            model.undo()
        }
    }

    private static func redo(_ model: AppModel) {
        if isComposing() { return }
        if let text = NSApp.keyWindow?.firstResponder as? NSText, text.undoManager?.canRedo == true {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else {
            model.redo()
        }
    }

    /// ⌘↩·⌘⌫: 글을 고치는 중이면(시트 안 글 칸 포함) 그 글 칸의 원래 동작(`text`), 시트가 떠 있으면 아무것도,
    /// 아니면 고른 티켓의 동작(`ticket`). 메뉴 단축키가 글 칸보다 먼저 키를 받기 때문이다.
    private static func ticketKey(text: () -> Void, ticket: () -> Void) {
        if isComposing() { return }
        guard let window = NSApp.keyWindow else { return }
        if window.firstResponder is NSText {
            text()
            return
        }
        guard window.attachedSheet == nil, window.sheetParent == nil, !(window is NSPanel) else { return }
        ticket()
    }

    /// 한글·일본어 입력기가 글자를 조합하는 중이면 실행 취소를 하지 않는다(조합 중에 자막 데이터를 바꾸면 조합이 깨진다).
    private static func isComposing() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
}

/// 프로젝트가 없으면 목록, 영상이 없으면 "영상 찾기", 그 밖에는 편집기.
private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.project == nil {
                ProjectListView()
            } else if model.videoMissing {
                MissingVideoView()
            } else {
                EditorView()
            }
        }
        // MKV 변환은 시트가 아니라 창 위에 덮어 보여 준다. 시트가 떠 있으면 앱 종료가 막혀
        // 종료 확인(변환 취소, ffmpeg 정리)이 불리지 않는다.
        .disabled(model.conversionProgress != nil)
        .overlay {
            if model.conversionProgress != nil { ConversionOverlay() }
        }
        .sheet(item: languageQuestion) { question in
            SourceLanguageSheet(question: question) { model.answerLanguage($0) }
        }
        .confirmationDialog(
            "이 영상의 프로젝트가 이미 있어요",
            isPresented: Binding(get: { model.existingProjectQuestion != nil },
                                 set: { if !$0 { model.answerExistingProject(.cancel) } }),
            titleVisibility: .visible, presenting: model.existingProjectQuestion
        ) { _ in
            Button("기존 프로젝트 열기") { model.answerExistingProject(.open) }
            Button("새 프로젝트 만들기") { model.answerExistingProject(.create) }
            Button("취소", role: .cancel) { model.answerExistingProject(.cancel) }
        } message: { question in
            Text("기존 프로젝트: \(question.projectName)\n새로 만들면 같은 영상으로 따로 작업해요. 이름은 나중에 바꿀 수 있어요.")
        }
        .alert(model.alertMessage ?? "", isPresented: alertShown) {
            Button("확인") { model.alertMessage = nil }
        }
        .background(CloseButtonQuits())
        .confirmationDialog("저장하지 않은 변경이 있어요", isPresented: confirmShown) {
            Button("저장") { model.resolvePendingAction(save: true) }
            Button("저장 안 함", role: .destructive) { model.resolvePendingAction(save: false) }
            Button("취소", role: .cancel) { model.resolvePendingAction(save: nil) }
        }
    }

    /// 닫힘(Esc 등)은 취소로 답한다. 버튼으로 답한 뒤에 다시 불려도 기다리는 답이 없어 아무것도 하지 않는다.
    private var languageQuestion: Binding<AppModel.LanguageQuestion?> {
        Binding(get: { model.languageQuestion }, set: { if $0 == nil { model.answerLanguage(nil) } })
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    private var confirmShown: Binding<Bool> {
        // 닫힘은 버튼이 처리한다. Escape는 .cancel 버튼("취소")으로 간다.
        Binding(get: { model.pendingAction != nil }, set: { _ in })
    }
}

/// 창의 닫기 단추를 "종료"로 돌린다. 창이 닫히기 전에 종료 확인(저장 확인)이 창에 붙어 뜬다.
private struct CloseButtonQuits: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let button = window?.standardWindowButton(.closeButton) else { return }
            button.target = NSApp
            button.action = #selector(NSApplication.terminate(_:))
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
