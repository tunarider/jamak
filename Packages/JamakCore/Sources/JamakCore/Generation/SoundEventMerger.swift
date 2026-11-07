import Foundation

public struct SoundWindow: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var label: String
    public var confidence: Double

    public init(startMs: Int, endMs: Int, label: String, confidence: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.label = label
        self.confidence = confidence
    }
}

public enum SoundEventMerger {
    /// 소리 분류 창을 라벨별로 합쳐 소리 조각으로 만든다.
    public static func clips(
        from windows: [SoundWindow], labels: SoundLabels, language: String,
        minConfidence: Double = 0.6, maxGapMs: Int = 500, minLengthMs: Int = 500
    ) -> [SubtitleClip] {
        var texts: [String: String] = [:]
        var kept: [SoundWindow] = []
        for window in windows where window.confidence >= minConfidence {
            if texts[window.label] == nil {
                guard let text = labels.text(for: window.label, language: language) else { continue }
                texts[window.label] = text
            }
            kept.append(window)
        }
        kept.sort { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.endMs < $1.endMs }

        // 라벨별로 열린 구간을 하나씩 유지한다(다른 라벨이 사이에 끼어도 합친다).
        var open: [String: (start: Int, end: Int)] = [:]
        var result: [SubtitleClip] = []
        func close(_ label: String) {
            guard let span = open.removeValue(forKey: label),
                  span.end - span.start >= minLengthMs, let text = texts[label] else { return }
            result.append(SubtitleClip(start: span.start, end: span.end, kind: .sound, text: text))
        }
        for window in kept {
            if let span = open[window.label], window.startMs - span.end <= maxGapMs {
                open[window.label] = (span.start, max(span.end, window.endMs))
            } else {
                close(window.label)
                open[window.label] = (window.startMs, window.endMs)
            }
        }
        for label in Array(open.keys) { close(label) }
        return result.sorted(by: SubtitleClip.timelineOrder)
    }

    /// 이미 있는 소리 조각과 시간이 겹치고 본문(앞뒤 공백 제외)이 같은 새 소리 조각을 뺀다. 겹치면 이미 있는 쪽을 남긴다.
    /// 다른 소리끼리는 겹쳐도 둔다. 새 음성 조각은 건드리지 않는다.
    /// 같은 결과를 다시 넣어도(소리 찾기를 다시 돌리거나 구간을 다시 받아써도) 소리 조각이 겹쳐 쌓이지 않는다.
    public static func droppingOverlaps(_ clips: [SubtitleClip], with existing: [SubtitleClip]) -> [SubtitleClip] {
        let sounds = existing.filter { $0.kind == .sound }
        return clips.filter { clip in
            guard clip.kind == .sound else { return true }
            let text = normalized(clip.text)
            return !sounds.contains { $0.start < clip.end && clip.start < $0.end && normalized($0.text) == text }
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
