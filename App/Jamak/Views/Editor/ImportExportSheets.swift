import JamakCore
import SwiftUI

// MARK: - srt 가져오기 시트

struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
}

/// "srt 가져오기": 지금 자막셋과 가져올 언어(ko, ja, en 중 하나)를 고른다. 기본값은 파일 이름 끝의 `.xx.srt`,
/// 없으면 작품 원어. 언어 추가와 덮어쓰기 확인은 시트가 닫힌 뒤 `EditorView`가 묻는다.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    let item: PendingImport
    let blocked: Bool
    let onImport: (Language) -> Void
    let onCancel: () -> Void
    let original: Language
    @State private var language: Language

    init(item: PendingImport, original: Language, blocked: Bool,
         onImport: @escaping (Language) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.blocked = blocked
        self.original = original
        self.onImport = onImport
        self.onCancel = onCancel
        _language = State(initialValue: AppModel.defaultLanguage(forSRT: item.url) ?? original)
    }

    private var set: CueSet? { model.currentSet }

    var body: some View {
        AISheetFrame(title: "srt 가져오기",
                     subtitle: "\(item.url.lastPathComponent) · \"\(set?.name ?? "")\" 자막셋에 가져와요.") {
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("가져올 언어")
                SheetDropdown(title: title(language), accessibility: "가져올 언어") {
                    Language.allCases.map { l in JMenuEntry(title: title(l)) { language = l } }
                }
                if let set, !set.languages.contains(language) {
                    SheetHint("\(language.displayName)는 자막셋에 없어서 더할지 물어봐요.").padding(.top, 6)
                }
            }
            if blocked {
                SheetHint("작업이 끝난 뒤에 가져올 수 있어요.")
            }
        } footer: {
            Button("취소", action: onCancel)
                .buttonStyle(.jSecondary)
                .keyboardShortcut(.cancelAction)
            Button("가져오기") { onImport(language) }
                .buttonStyle(.jPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(blocked || set == nil)
        }
    }

    /// 예: "일본어 — 작품 원어".
    private func title(_ l: Language) -> String {
        l == original ? "\(l.displayName) — 작품 원어" : l.displayName
    }
}

// MARK: - 내보내기 시트

/// 내보내기 형식.
enum ExportFormat: Equatable {
    case srt
    case video(SubtitleContainer)
}

struct ExportChoice {
    let languages: [Language]
    let fallback: Bool
    let format: ExportFormat
}

struct ExportRequest {
    let folder: URL
    let languages: [Language]
    let fallback: Bool
    /// 덮어쓸 파일 수.
    let count: Int
}

/// "내보내기": 지금 자막셋의 언어(체크), 빈 칸 채우기, 출력 형식(srt 파일 / 자막을 넣은 영상).
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    /// 다른 무거운 작업 중이라 영상으로 내보낼 수 없다.
    let videoBlocked: Bool
    let onExport: (ExportChoice) -> Void
    let onCancel: () -> Void
    let original: Language
    @State private var selected: Set<Language>
    @State private var fallback = true
    @State private var asVideo = false
    @State private var container: SubtitleContainer = .mkv

    init(original: Language, videoBlocked: Bool, onExport: @escaping (ExportChoice) -> Void,
         onCancel: @escaping () -> Void) {
        self.videoBlocked = videoBlocked
        self.onExport = onExport
        self.onCancel = onCancel
        self.original = original
        _selected = State(initialValue: [original])
    }

    private var set: CueSet? { model.currentSet }

    /// 작품 원어를 앞에 둔다.
    private var languages: [Language] {
        guard let set else { return [] }
        return [original] + set.languages.filter { $0 != original }
    }

    private var chosen: [Language] { languages.filter(selected.contains) }

    var body: some View {
        AISheetFrame(title: "내보내기", subtitle: "\"\(set?.name ?? "")\" 자막셋을 내보내요.") {
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("언어")
                ForEach(languages, id: \.self) { l in
                    SheetCheck(title: l == original ? "\(l.displayName) — 작품 원어" : l.displayName,
                               detail: nil,
                               isOn: Binding(get: { selected.contains(l) },
                                             set: { if $0 { selected.insert(l) } else { selected.remove(l) } }))
                }
                SheetCheck(title: "빈 칸은 작품 원어로 채우기",
                           detail: "그 언어 칸이 빈 조각은 작품 원어 문장을 넣어요", isOn: $fallback)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                SheetLabel("내보낼 형식")
                SheetRadio(title: "srt 파일", detail: "언어마다 영상이름.<언어코드>.srt", isOn: !asVideo) { asVideo = false }
                SheetRadio(title: "자막을 넣은 영상", detail: "언어마다 자막 트랙 하나", isOn: asVideo) { asVideo = true }
                if asVideo {
                    JSegmented([(value: SubtitleContainer.mkv, label: "MKV", systemImage: nil),
                                (value: SubtitleContainer.mp4, label: "MP4", systemImage: nil)],
                               selection: $container)
                        .padding(.top, 4)
                    if container == .mp4 {
                        SheetHint("MP4에서는 화면 자막의 위쪽 위치가 무시될 수 있어요.").padding(.top, 6)
                    }
                    if videoBlocked {
                        SheetHint("다른 작업이 끝난 뒤에 영상으로 내보낼 수 있어요.").padding(.top, 6)
                    }
                }
            }
        } footer: {
            Button("취소", action: onCancel)
                .buttonStyle(.jSecondary)
                .keyboardShortcut(.cancelAction)
            Button(asVideo ? "영상으로 내보내기" : "srt로 내보내기") {
                onExport(ExportChoice(languages: chosen, fallback: fallback, format: asVideo ? .video(container) : .srt))
            }
            .buttonStyle(.jPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty || (asVideo && videoBlocked))
        }
    }
}
