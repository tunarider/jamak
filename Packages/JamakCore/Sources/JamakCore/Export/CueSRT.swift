import Foundation

/// 여러 언어 자막셋과 srt 한 파일(한 언어) 사이의 가져오기·내보내기.
public enum CueSRT {
    public struct ImportPlan: Equatable {
        /// 기존 조각 id → 그 언어 칸에 넣을 문장
        public var filled: [UUID: String]
        /// 짝이 없는 줄로 만든 새 조각(그 언어 칸만 채움)
        public var newCues: [Cue]
        /// `filled` 중 그 언어에 이미 다른 문장이 있어 덮어쓰게 되는 조각 수
        public var overwrites: Int

        public init(filled: [UUID: String], newCues: [Cue], overwrites: Int) {
            self.filled = filled
            self.newCues = newCues
            self.overwrites = overwrites
        }
    }

    /// 빈 자막셋이면 줄마다 새 조각. 아니면 같은 종류에서 겹침이 가장 큰 조각(같으면 먼저 시작), 조각당 한 줄, 짝 없는 줄은 새 조각.
    /// `srt`는 `SRTCodec.parse`로 읽은 조각(종류 부호는 이미 벗겨짐)이다.
    public static func importPlan(_ srt: [SubtitleClip], into set: CueSet, language: Language) -> ImportPlan {
        let lines = srt.enumerated().sorted {
            let (a, b) = ($0.element, $1.element)
            if a.start != b.start { return a.start < b.start }
            return $0.offset < $1.offset
        }.map(\.element)
        // 후보는 시작 → 끝 → id 순. 겹침이 같으면 앞선 것을 고른다. 시작 순이니 줄 끝 이후에 시작하는
        // 후보부터는 겹칠 수 없어 거기서 멈춘다.
        let candidates = set.cuesInTimelineOrder
        var taken = Set<UUID>()
        var filled: [UUID: String] = [:]
        var newCues: [Cue] = []
        var overwrites = 0

        for line in lines {
            var best: Cue?
            var bestOverlap = 0
            for cue in candidates {
                if cue.start >= line.end { break }
                guard cue.kind == line.kind, cue.end > line.start, !taken.contains(cue.id) else { continue }
                let overlap = min(cue.end, line.end) - max(cue.start, line.start)
                if best == nil || overlap > bestOverlap { (best, bestOverlap) = (cue, overlap) }
            }
            if let best {
                taken.insert(best.id)
                filled[best.id] = line.text
                let old = best.text(language)
                if !old.isEmpty && old != line.text { overwrites += 1 }
            } else {
                newCues.append(Cue(start: line.start, end: line.end, kind: line.kind,
                                   texts: [language: line.text]))
            }
        }
        return ImportPlan(filled: filled, newCues: newCues, overwrites: overwrites)
    }

    /// fallback true면 빈 칸을 작품 원어로 채운다. 종류 부호를 붙인다. 문장이 빈 조각은 빼고 1부터 번호를 매긴다.
    public static func export(_ set: CueSet, language: Language, original: Language, fallback: Bool) -> String {
        let clips: [SubtitleClip] = set.cuesInTimelineOrder.compactMap { cue in
            var text = cue.text(language)
            if text.isEmpty && fallback { text = cue.text(original) }
            guard !text.isEmpty else { return nil }
            return SubtitleClip(id: cue.id, start: cue.start, end: cue.end, kind: cue.kind, text: text)
        }
        return SRTCodec.serialize(clips)
    }
}
