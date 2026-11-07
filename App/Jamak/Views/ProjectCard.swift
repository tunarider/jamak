import AppKit
import JamakCore
import JamakMedia
import SwiftUI

/// 포스터 이미지 캐시(앱 실행 동안, 프로젝트 폴더별).
@MainActor
private enum PosterCache {
    static let images = NSCache<NSString, NSImage>()
}

/// 프로젝트 카드(시안 .pc). 포스터, 길이, 이름, 언어 알약, 작업 네 칸, 상태 한 줄, 마지막으로 연 때.
/// 열 수 없는 폴더는 흐린 카드에 까닭 한 줄만 보인다. 눌러도 열지 않는다.
/// 예전 형식과 깨진 프로젝트는 우클릭 삭제만 된다(깨진 것은 목록이 경고와 함께 확인을 받는다).
/// 새 버전 앱에서 만든 프로젝트는 지우지 않는다(이 앱이 읽지 못할 뿐 멀쩡하다). "Finder에서 보기"만 있다.
struct ProjectCard: View {
    let summary: ProjectSummary
    let isBusy: Bool
    let open: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        if let state = summary.state, summary.canOpen {
            CurrentProjectCard(summary: summary, state: state, isBusy: isBusy, open: open, reveal: reveal,
                               rename: rename, delete: delete)
        } else {
            UnopenableProjectCard(summary: summary, isBusy: isBusy, reveal: reveal, delete: delete)
        }
    }

    /// 오늘이면 `HH:mm`, 어제면 "어제", 그 밖은 "M월 d일". 기록이 없으면 빈 글자.
    static func lastOpened(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "어제"
        } else {
            formatter.dateFormat = "M월 d일"
        }
        return formatter.string(from: date)
    }
}

/// 열 수 없는 폴더의 카드(예전 형식, 새 형식, 깨진 project.json).
private struct UnopenableProjectCard: View {
    let summary: ProjectSummary
    let isBusy: Bool
    let reveal: () -> Void
    let delete: () -> Void

    static func note(_ format: ProjectSummary.Format) -> String {
        switch format {
        case .newer: "새 버전 앱에서 만든 프로젝트예요"
        case .corrupt: "프로젝트 파일을 읽을 수 없어요"
        case .legacy, .current: "예전 형식이라 열 수 없어요"
        }
    }

    private var note: String { Self.note(summary.format) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Theme.bg2, Theme.bg0], startPoint: .top, endPoint: .bottom))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            VStack(alignment: .leading, spacing: 9) {
                Text(summary.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            .padding(.top, 12)
            .padding(.horizontal, 13)
            .padding(.bottom, 13)
        }
        .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .opacity(0.5)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.name), \(note)")
        .contextMenu {
            Button("Finder에서 보기", action: reveal)
            // 새 버전 앱의 프로젝트는 멀쩡하니 지우게 하지 않는다.
            if summary.format != .newer {
                Divider()
                Button("삭제", role: .destructive, action: delete).disabled(isBusy)
            }
        }
    }
}

private struct CurrentProjectCard: View {
    let summary: ProjectSummary
    let state: ProjectState
    /// 생성·영상 열기·변환 중이다. 열기와 삭제를 막는다.
    let isBusy: Bool
    let open: () -> Void
    let reveal: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    @State private var poster: NSImage?
    @State private var isMissing = false
    @State private var isHovering = false

    private var status: WorkflowStatus {
        WorkflowStatus(state: state, hasSourceSet: summary.cueCount > 0)
    }

    /// 티켓은 처리하면 지워지므로 남은 티켓이 곧 미해결이다. 없는 조각의 티켓은 세지 않는다.
    private var openTicketCount: Int { summary.openTicketCount }

    /// 어느 자막셋에서든 그 언어 번역을 마쳤다.
    private func isTranslated(_ language: Language) -> Bool {
        (state.setTranslations ?? [:]).contains { key, progress in
            key.hasSuffix("/\(language.rawValue)") && progress.isComplete
        }
    }

    var body: some View {
        let status = status
        let line = statusLine(status)
        let when = ProjectCard.lastOpened(state.lastOpenedAt)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                posterView
                VStack(alignment: .leading, spacing: 9) {
                    Text(summary.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack {
                        HStack(spacing: 4) {
                            ForEach(summary.languages, id: \.self) { lang in
                                LanguagePill(code: lang.rawValue, isDone: isTranslated(lang))
                            }
                        }
                        Spacer(minLength: 6)
                        steps(status)
                    }
                    HStack {
                        Text(line.text)
                            .foregroundStyle(line.isStopped ? Theme.accent : Theme.text3)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(when).monospacedDigit().foregroundStyle(Theme.text3)
                    }
                    .font(.system(size: 11))
                }
                .padding(.top, 12)
                .padding(.horizontal, 13)
                .padding(.bottom, 13)
            }
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(isHovering ? Theme.line2 : Theme.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([summary.name, Timecode.short(state.videoDurationMs), line.text, when,
                                 isMissing ? "영상을 찾을 수 없어요" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("열기", action: open).disabled(isBusy)
            Button("이름 바꾸기…", action: rename).disabled(isBusy)
            Button("Finder에서 보기", action: reveal)
            Divider()
            Button("삭제", role: .destructive, action: delete).disabled(isBusy)
        }
        .task(id: summary.folder) { await loadPosterAndVideoState() }
    }

    // MARK: 포스터

    private var posterView: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.bg2, Theme.bg0], startPoint: .top, endPoint: .bottom))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let poster {
                    Image(nsImage: poster).resizable().scaledToFill()
                }
            }
            .overlay {
                if isMissing {
                    Text("영상을 찾을 수 없어요 · 다시 지정")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xFFB4A8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.55))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(Timecode.short(state.videoDurationMs))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
            .clipped()
    }

    /// 포스터 프레임을 메인 밖에서 읽고, 영상이 있는지도 거기서 본다(북마크 해석은 메인에서 하지 않는다).
    private func loadPosterAndVideoState() async {
        let folder = summary.folder
        let summary = summary
        let second = PosterFrame.second(durationMs: state.videoDurationMs)
        let key = "\(folder.path)#\(second)" as NSString
        let cached = PosterCache.images.object(forKey: key)
        let (data, missing): (Data?, Bool) = await Task.detached(priority: .utility) {
            let url = folder.appendingPathComponent(AppModel.framesFolderName, isDirectory: true)
                .appendingPathComponent(FrameSampler.fileName(second: second))
            return (cached == nil ? try? Data(contentsOf: url) : nil, AppModel.isVideoMissing(summary))
        }.value
        isMissing = missing
        if let cached {
            poster = cached
        } else if let data, let image = NSImage(data: data) {
            PosterCache.images.setObject(image, forKey: key)
            poster = image
        } else {
            poster = nil
        }
    }

    // MARK: 작업 네 칸

    private func steps(_ status: WorkflowStatus) -> some View {
        HStack(spacing: 3) {
            ForEach([status.transcribe, status.analyze, status.correct, status.translate].enumerated().map { $0 }, id: \.offset) { _, step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step == .done ? Theme.fixed : step == .partial ? Theme.accent : Theme.line2)
                    .frame(width: 18, height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: 상태 한 줄

    private func statusLine(_ status: WorkflowStatus) -> (text: String, isStopped: Bool) {
        if openTicketCount > 0 { return ("티켓 \(openTicketCount)", false) }
        if let step = status.stoppedStepName { return ("\(step)에서 멈춤", true) }
        if summary.cueCount == 0 && status.transcribe == .none { return ("자막 없음", false) }
        // 생성 기록이 있는데 아직 안 끝난 단계가 있으면(멈춤은 위에서 걸러짐) 어디까지 했는지 보인다.
        if state.setGeneration?.isEmpty == false, status.transcribe == .done {
            if status.analyze == .none { return ("받아쓰기만 함", false) }
            if status.correct == .none { return ("원문 검토 전", false) }
        }
        return ("검토 끝", false)
    }

}

/// 언어 알약(시안 .lang-pill). 번역을 마친 언어는 초록.
private struct LanguagePill: View {
    let code: String
    let isDone: Bool

    var body: some View {
        Text(code.uppercased())
            .font(.system(size: 10.5))
            .foregroundStyle(isDone ? Theme.fixedText : Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isDone ? Theme.fixed.opacity(0.15) : Theme.bg3, in: RoundedRectangle(cornerRadius: 5))
    }
}
