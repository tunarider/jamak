import AVKit
import JamakCore
import SwiftUI

/// 영상 패널. `AVPlayerView`(컨트롤 없음) 위에 재생 위치의 자막을 겹쳐 보여 준다(설계 5절).
/// 출력 언어를 보이고, 빈 칸은 작품 원어로 대신 보인다(기울임, 흐리게). "전체"면 작품 원어 먼저, 나머지 언어는 작게 보인다.
struct PlayerPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let original = model.originalLanguage
        let lines = original.flatMap { original in
            model.currentSet?.displayCues(at: model.playheadMs, output: model.outputLanguage, original: original,
                                          hidden: model.hiddenKinds)
        } ?? []
        let isAll = model.outputLanguage == .all
        let primary = lines.filter { !isAll || $0.language == original }.map(OverlayLine.init)
        let secondary = isAll ? lines.filter { $0.language != original }.map(OverlayLine.init) : []
        ZStack {
            PlayerView(player: model.player)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 10)
            SubtitleOverlay(lines: primary, secondary: secondary)
        }
        .background(Theme.bg0)
    }
}

/// 겹쳐 보기 한 줄(보기 전용). id는 조각 id와 언어로 정해 그릴 때마다 같다.
struct OverlayLine: Identifiable, Equatable {
    let id: UUID
    let kind: SubtitleKind
    let text: String
    /// 출력 언어가 비어 작품 원어로 대신 보인 줄.
    let isFallback: Bool

    init(id: UUID, kind: SubtitleKind, text: String, isFallback: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isFallback = isFallback
    }

    init(_ line: DisplayCue) {
        self.init(id: Self.lineID(line.cue.id, line.language), kind: line.cue.kind, text: line.text,
                  isFallback: line.isFallback)
    }

    /// 조각 id의 첫 바이트에 언어 번호를 섞는다. 같은 조각의 다른 언어 줄끼리 겹치지 않는다.
    private static func lineID(_ cueID: UUID, _ language: Language) -> UUID {
        var bytes = cueID.uuid
        let index = Language.allCases.firstIndex(of: language) ?? 0
        bytes.0 ^= UInt8(index + 1)
        return UUID(uuid: bytes)
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// 화면 조각은 위쪽, 음성·소리는 아래쪽. 겹치면 세로로 쌓는다.
/// `secondary`("전체"의 작품 원어가 아닌 언어)는 같은 위치(위쪽·아래쪽 묶음)에서 현재 줄들을 다 쓴 뒤 그 아래에 작고 흐리게 모아 보인다.
/// 대신 보인 작품 원어 줄은 기울이고 흐리게 보인다(시안 .sub.fallback).
struct SubtitleOverlay: View {
    /// 레인 순서(화면, 음성, 소리)로 정렬된 줄.
    let lines: [OverlayLine]
    var secondary: [OverlayLine] = []

    var body: some View {
        GeometryReader { geo in
            let base = max(12, min(28, geo.size.height * 0.055))
            VStack(spacing: 4) {
                stack(lines.filter { $0.kind == .screen }, secondary.filter { $0.kind == .screen }, base: base)
                Spacer(minLength: 0)
                stack(lines.filter { $0.kind != .screen }, secondary.filter { $0.kind != .screen }, base: base)
            }
            .padding(.vertical, geo.size.height * 0.06)
            .padding(.horizontal, 16)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private func stack(_ lines: [OverlayLine], _ secondary: [OverlayLine], base: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(lines) { line($0, base: base, factor: 1) }
            ForEach(secondary) { line($0, base: base, factor: 0.8).opacity(0.75) }
        }
    }

    private func line(_ line: OverlayLine, base: CGFloat, factor: CGFloat) -> some View {
        let size = base * Self.scale(line.kind) * factor
        return Text(line.text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(line.isFallback ? Self.fallbackColor : Self.color(line.kind))
            // 한글·일본어 글꼴에는 기울임 모양이 없으니 글자를 기울여 그린다(아래쪽을 왼쪽으로, 가운데는 그대로).
            .transformEffect(line.isFallback
                ? CGAffineTransform(a: 1, b: 0, c: -Self.fallbackSlant, d: 1, tx: size * Self.fallbackSlant * 0.6, ty: 0)
                : .identity)
            .multilineTextAlignment(.center)
            .shadow(color: .black, radius: 2)
            .shadow(color: .black, radius: 1, y: 2)
    }

    /// 대신 보인 작품 원어 줄(시안 #C9C6BF).
    static let fallbackColor = Color(hex: 0xC9C6BF)
    /// 대신 보인 줄의 기울기(타임라인과 같다).
    static let fallbackSlant: CGFloat = 0.18

    private static func scale(_ kind: SubtitleKind) -> CGFloat {
        switch kind {
        case .speech: 1
        case .sound: 0.76
        case .screen: 0.72
        }
    }

    private static func color(_ kind: SubtitleKind) -> Color {
        switch kind {
        case .speech: .white
        case .sound: Color(red: 1, green: 0.9, blue: 0.69)      // #ffe6b0
        case .screen: Color(red: 0.9, green: 0.86, blue: 1)     // #e6dcff
        }
    }
}
