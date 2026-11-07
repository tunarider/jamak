import JamakCore
import SwiftUI

/// 재생 막대(설계 문서 3.3, 높이 54): 큰 시간 표기 | 이전 조각·1초 뒤로·재생·1초 앞으로·다음 조각 | 출력 언어 세그먼트·음량.
struct Transport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            BigTimecode()
                .frame(maxWidth: .infinity, alignment: .leading)
            Controls()
                .layoutPriority(1)
            HStack(spacing: 6) {
                OverlaySegment()
                RateButton()
                MuteButton()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(Theme.bg1)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// `현재 / 전체`. 재생 위치가 바뀔 때마다 이 뷰만 다시 그린다.
private struct BigTimecode: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Timecode.full(model.playheadMs))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("/ \(Timecode.full(model.durationMs))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Button { jumpClip(forward: false) } label: { Image(systemName: "backward.end.fill") }
                .help("이전 조각").accessibilityLabel("이전 조각")
            Button { skip(-1000) } label: { Image(systemName: "gobackward.1") }
                .help("1초 뒤로").accessibilityLabel("1초 뒤로")
            PlayButton()
            Button { skip(1000) } label: { Image(systemName: "goforward.1") }
                .help("1초 앞으로").accessibilityLabel("1초 앞으로")
            Button { jumpClip(forward: true) } label: { Image(systemName: "forward.end.fill") }
                .help("다음 조각").accessibilityLabel("다음 조각")
        }
        .buttonStyle(.jIcon)
    }

    private func skip(_ delta: Int) {
        let target = model.playheadMs + delta
        model.seek(ms: model.durationMs > 0 ? min(target, model.durationMs) : target)
    }

    /// 현재 자막셋에서 재생 위치 앞뒤 조각의 시작으로 간다. 눌렀을 때만 찾는다.
    private func jumpClip(forward: Bool) {
        guard model.currentSet != nil else { return }
        let clips = model.currentView.clips
        let hidden = model.hiddenKinds
        let clip = forward
            ? ClipNavigation.next(after: model.playheadMs, in: clips, hidden: hidden)
            : ClipNavigation.previous(before: model.playheadMs, in: clips, hidden: hidden)
        guard let clip else { return }
        model.reveal(kind: clip.kind)
        model.select(clip.id)
        model.seek(ms: clip.start)
    }
}

/// 재생/일시정지(시안 .play: 40×34, bg3, 반경 8).
private struct PlayButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 34)
                .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(model.isPlaying ? "일시정지 (Space)" : "재생 (Space)")
        .accessibilityLabel(model.isPlaying ? "일시정지" : "재생")
    }
}

/// 출력 언어 세그먼트(시안 .out-seg): 자막셋 언어들(작품 원어 먼저, "원어" 작은 표시) + "전체".
/// 자막셋 언어가 하나면 숨는다.
private struct OverlaySegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let set = model.currentSet, let original = model.originalLanguage, set.languages.count > 1 {
            let ordered = [original] + set.languages.filter { $0 != original }
            HStack(spacing: 2) {
                ForEach(ordered, id: \.self) { language in
                    OutputCell(label: language.displayName, isDefault: language == original,
                               isSelected: model.outputLanguage == .one(language)) {
                        model.setOutputLanguage(.one(language))
                    }
                }
                OutputCell(label: "전체", isDefault: false, isSelected: model.outputLanguage == .all) {
                    model.setOutputLanguage(.all)
                }
            }
            .padding(2)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay { RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.line, lineWidth: 1) }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("출력 언어")
        }
    }
}

/// 출력 언어 세그먼트 한 칸(`JSegmented`의 칸과 같은 모양). 작품 원어에는 노란 "원어"가 붙는다.
private struct OutputCell: View {
    let label: String
    let isDefault: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(label).font(.system(size: 11.5))
                if isDefault {
                    Text("원어").font(.system(size: 9)).foregroundStyle(Theme.accent)
                }
            }
            .foregroundStyle(isSelected || isHovering ? Theme.text : Theme.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isSelected ? Theme.bg3 : isHovering ? Theme.bg3.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isDefault ? "\(label) 원어" : label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 재생 속도 메뉴(Shift+, / Shift+. 로도 바꾼다).
private struct RateButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        JMenuButton(style: .jIcon, items: {
            AppModel.playbackRates.map { rate in
                (title: (rate == model.playbackRate ? "✓ " : "    ") + Self.label(rate),
                 action: { model.setPlaybackRate(rate) })
            }
        }) {
            Text(Self.label(model.playbackRate))
                .font(.system(size: 11.5))
                .monospacedDigit()
        }
        .fixedSize()
        .help("재생 속도 (Shift+, / Shift+.)")
        .accessibilityLabel("재생 속도 \(Self.label(model.playbackRate))")
    }

    static func label(_ rate: Float) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return text + "×"
    }
}

/// 음소거 토글.
private struct MuteButton: View {
    @Environment(AppModel.self) private var model
    @State private var isMuted = false

    var body: some View {
        Button {
            isMuted.toggle()
            model.player.isMuted = isMuted
        } label: {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.jIcon)
        .help(isMuted ? "소리 켜기" : "음소거")
        .accessibilityLabel(isMuted ? "소리 켜기" : "음소거")
        .onAppear { isMuted = model.player.isMuted }
    }
}
