import AppKit
import JamakCore
import JamakMedia
import SwiftUI

/// 인스펙터 카드 틀(시안 .card): bg2 바탕, line2 테두리, 반경 9. 머리 줄과 구분선 아래에 본문.
struct InspectorCard<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { header() }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
            Rectangle().fill(Theme.line).frame(height: 1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line2, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// 생성 중이라 자막셋이 잠겼을 때 인스펙터 맨 위에 두는 카드(설계 문서 3.4).
struct LockCard: View {
    var body: some View {
        InspectorCard {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Text("자막을 만드는 중이에요")
        } content: {
            Text("끝나면 결과를 한 번에 넣어요. 그동안 원문 자막셋은 보기만 할 수 있어요. 재생과 이동은 그대로 돼요.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.top, 10)
                .padding(.bottom, 11)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 한 언어 칸에 열린 티켓의 카드. 썸네일은 칸마다 한 번 읽는다.
/// `clip`은 그 칸의 언어 보기(문장 = 그 언어 문장)다.
struct ReviewCards: View {
    @Environment(AppModel.self) private var model
    let clip: SubtitleClip
    let ticket: Ticket

    @State private var thumbnails: [ReviewThumbnail] = []

    var body: some View {
        ReviewCard(clip: clip, ticket: ticket, thumbnails: thumbnails)
        // 조각을 고른 동안 한 번만 읽는다(시간을 고치면 다시 읽는다).
        .task(id: ThumbnailKey(clipID: clip.id, start: clip.start, end: clip.end)) {
            let folder = model.project?.folder.appendingPathComponent(AppModel.framesFolderName, isDirectory: true)
            let loaded = await Self.loadThumbnails(seconds: GenerationController.frameSeconds(for: clip), folder: folder)
            // 읽는 사이 다른 조각으로 바뀌었으면(작업이 취소됐으면) 앞 조각의 썸네일을 넣지 않는다.
            guard !Task.isCancelled else { return }
            thumbnails = loaded
        }
    }

    private struct ThumbnailKey: Equatable {
        let clipID: UUID
        let start: Int
        let end: Int
    }

    /// 캐시(`frames/`)에 있는 프레임만 메인 액터 밖에서 읽는다. 없으면 빈 배열.
    private static func loadThumbnails(seconds: [Int], folder: URL?) async -> [ReviewThumbnail] {
        guard let folder else { return [] }
        let loaded: [(Int, Data)] = await Task.detached(priority: .userInitiated) {
            seconds.compactMap { second in
                let url = folder.appendingPathComponent(FrameSampler.fileName(second: second))
                return (try? Data(contentsOf: url)).map { (second, $0) }
            }
        }.value
        return loaded.compactMap { second, data in
            NSImage(data: data).map { ReviewThumbnail(second: second, image: $0) }
        }
    }
}

struct ReviewThumbnail: Identifiable {
    let second: Int
    let image: NSImage
    var id: Int { second }

    /// 예: "14:22", 한 시간이 넘으면 "1:02:03".
    var label: String { Timecode.short(second * 1000) }
}

/// 티켓 카드(시안 .card): 머리(티켓 단계, 제목, 출처), 썸네일, 그리고 티켓 전체의 상세(이유, 링크된 조각마다
/// 비교, 버튼). 반영·미반영은 티켓 단위라 다른 조각의 변경도 함께 보인다. 지금 고른 조각은 강조한다.
struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let clip: SubtitleClip
    let ticket: Ticket
    let thumbnails: [ReviewThumbnail]

    private var isSuspect: Bool { ticket.level == .suspect }

    var body: some View {
        InspectorCard {
            mark
            Text(isSuspect ? "확인이 필요해요" : "자동으로 고쳤어요")
            Spacer(minLength: 0)
            Text(TicketText.source(ticket))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !thumbnails.isEmpty {
                    thumbnailRow
                        .padding(.horizontal, 11)
                        .padding(.top, 10)
                }
                TicketDetail(ticket: ticket, starts: starts, focusCueID: clip.id, showsHeader: false)
                    .padding(.horizontal, 11)
                    .padding(.top, 10)
                    .padding(.bottom, 11)
            }
        }
    }

    /// 링크된 조각의 시작 시간.
    private var starts: [UUID: Int] {
        let ids = Set(ticket.cueIDs)
        return Dictionary((model.currentSet?.cues ?? []).filter { ids.contains($0.id) }.map { ($0.id, $0.start) },
                          uniquingKeysWith: { first, _ in first })
    }

    private var mark: some View {
        Text(isSuspect ? "!" : "✓")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(isSuspect ? Color(hex: 0x2A0B0A) : Color(hex: 0x0B2A1F))
            .frame(width: 16, height: 16)
            .background(isSuspect ? Theme.suspect : Theme.fixed, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    private var thumbnailRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                if i < thumbnails.count {
                    thumbnail(thumbnails[i])
                } else {
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                }
            }
        }
    }

    private func thumbnail(_ item: ReviewThumbnail) -> some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .overlay(alignment: .bottomLeading) {
                Text(item.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: 0xDFE3E8))
                    .shadow(color: .black, radius: 1, y: 1)
                    .padding(.leading, 4)
                    .padding(.bottom, 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement()
            .accessibilityLabel("\(item.label) 화면")
    }
}
