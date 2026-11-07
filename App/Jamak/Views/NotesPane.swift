import JamakCore
import Observation
import SwiftUI

/// 노트 패널의 글. 입력이 1초 멈추면 저장하고, 닫을 때(프로젝트를 닫거나 앱을 끝낼 때)도 저장한다.
@MainActor @Observable
final class NotesEditing {
    private(set) var text = ""
    /// LLM(분석, 용어집)이 노트를 쓰는 중이다. 패널은 읽기 전용이다.
    var isLocked = false

    @ObservationIgnored private var edited = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var write: ((String) throws -> Void)?
    @ObservationIgnored private var onError: (Error) -> Void = { _ in }

    static let autosaveDelay: Duration = .seconds(1)

    /// 새 프로젝트의 노트를 연다(열려 있던 노트는 먼저 저장한다).
    func open(text: String, write: @escaping (String) throws -> Void, onError: @escaping (Error) -> Void) {
        close()
        self.text = text
        self.write = write
        self.onError = onError
    }

    /// 쓰던 내용을 저장하고 닫는다.
    func close() {
        flush()
        write = nil
        text = ""
        isLocked = false
    }

    func edit(_ new: String) {
        guard !isLocked, write != nil, new != text else { return }
        text = new
        edited = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 저장하지 않은 입력이 있으면 바로 저장한다.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard edited, let write else { return }
        do {
            try write(text)
            edited = false   // 저장에 실패하면 남겨 두어 다음 저장(입력, 패널 닫기, 종료)에 다시 쓴다.
        } catch {
            onError(error)
        }
    }

    /// 파일에서 다시 읽은 글로 바꾼다(저장하지 않은 입력은 없다고 본다).
    func reload(text: String) {
        saveTask?.cancel()
        saveTask = nil
        edited = false
        self.text = text
    }
}

/// 인스펙터 "작품 노트" 탭: notes.md를 그대로 고친다(탭 머리가 이름을 보이니 따로 제목을 두지 않는다).
struct NotesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(GenerationController.self) private var generation
    @FocusState private var focused: Bool

    var body: some View {
        let notes = model.notes
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    notes.flush()
                    generation.requestNotesRewrite(model: model)
                } label: {
                    Label("노트 새로 쓰기", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.jGhost)
                .disabled(!canAnalyze)
                .help(analyzeHelp)
                .fixedSize()
            }
            if notes.isLocked {
                Text("LLM이 노트를 쓰는 중이에요. 끝나면 다시 고칠 수 있어요.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            TextEditor(text: Binding(get: { notes.text }, set: { notes.edit($0) }))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(focused ? Theme.accent : Theme.line2, lineWidth: 1)
                }
                .disabled(notes.isLocked)
                .opacity(notes.isLocked ? 0.5 : 1)
                .accessibilityLabel("작품 노트")
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        // 탭을 바꾸거나 인스펙터를 닫으면 쓰던 내용을 바로 저장한다.
        .onDisappear { notes.flush() }
    }

    /// 메뉴 "검토 › 노트 새로 쓰기"와 같은 조건: 작업이 없고, 지금 자막셋 작품 원어 칸에 문장이 있다.
    /// LLM 준비는 누를 때 확인해 안내한다.
    private var canAnalyze: Bool {
        !generation.isRunning && model.project != nil && GenerationController.canRunLLM(model)
    }

    private var analyzeHelp: String {
        if generation.isRunning { return "작업 중에는 노트를 새로 쓸 수 없어요" }
        if !GenerationController.canRunLLM(model) { return "지금 자막셋의 작품 원어 칸에 문장이 있어야 노트를 쓸 수 있어요" }
        return "지금 노트를 지우고, 작품 원어 문장과 장면 메모를 분석해 노트를 새로 써요. 자막은 바뀌지 않아요"
    }
}
