import Foundation

/// 위스퍼가 돌려준 단어 하나(단어 타임스탬프). 일본어는 토큰 단위라 한두 글자일 수 있다.
public struct TranscriptWord: Equatable, Sendable {
    public var text: String, startSeconds: Double, endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// 위스퍼가 돌려준 세그먼트 하나. `words`는 단어 타임스탬프를 켰을 때만 있다.
public struct TranscriptSegment: Equatable, Sendable {
    public var startSeconds: Double, endSeconds: Double, text: String
    public var avgLogprob: Double, noSpeechProb: Double
    public var words: [TranscriptWord]

    public init(startSeconds: Double, endSeconds: Double, text: String, avgLogprob: Double, noSpeechProb: Double,
                words: [TranscriptWord] = []) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.words = words
    }
}

/// 위스퍼 세그먼트를 자막 조각으로 바꾼다.
public enum TranscriptMapper {
    private static let minDurationMs = 300
    private static let bracketPairs: [(open: Character, close: Character)] = [
        ("[", "]"), ("(", ")"), ("［", "］"), ("（", "）"),
    ]

    /// `keepUnsure`(강하게 받아쓰기): 위스퍼가 "말이 없을 것 같다"고 본 줄도 버리지 않는다.
    public static func clips(from segments: [TranscriptSegment], offsetMs: Int = 0,
                             keepUnsure: Bool = false) -> [SubtitleClip] {
        var mapped: [SubtitleClip] = []
        for segment in TranscriptRefiner.refine(segments) {
            let text = stripSpecialTokens(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || isMusicNotesOnly(text) { continue }
            if !keepUnsure && segment.noSpeechProb > 0.6 && segment.avgLogprob < -1.0 { continue }

            var kind = SubtitleKind.speech
            var body = text
            if let inner = unbracketed(text) {
                kind = .sound
                body = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || isNonSpeechMarker(body) { continue }
            }

            let start = Int((segment.startSeconds * 1000).rounded()) + offsetMs
            var end = Int((segment.endSeconds * 1000).rounded()) + offsetMs
            if end - start < minDurationMs { end = start + minDurationMs }
            mapped.append(SubtitleClip(start: start, end: end, kind: kind, text: body))
        }
        return collapseRepeats(mapped)
    }

    /// 위스퍼가 소리가 없을 때 내는 표시와 음악 표시. 괄호 안 본문 전체가 이것이면 버린다(대소문자 무시).
    /// 음악은 자막으로 만들지 않는다.
    private static let nonSpeechMarkers: Set<String> = [
        "blank_audio", "blank", "silence", "no speech", "inaudible", "無音", "沈黙", "무음", "*", "…", "...",
        "音楽", "music", "음악", "bgm",
    ]

    private static func isNonSpeechMarker(_ body: String) -> Bool {
        nonSpeechMarkers.contains(body.lowercased()) || isMusicNotesOnly(body)
    }

    /// 음표와 물결, 공백만 있는 줄(가사가 없는 음악 표시).
    private static func isMusicNotesOnly(_ text: String) -> Bool {
        let notes: Set<Character> = ["♪", "♫", "♬", "♩", "〜", "~", "～"]
        return text.contains { notes.contains($0) } && text.allSatisfy { notes.contains($0) || $0.isWhitespace }
    }

    private static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression)
    }

    /// 전체가 한 쌍의 괄호로 감싸졌으면 괄호를 뗀 본문을, 아니면 nil.
    private static func unbracketed(_ text: String) -> String? {
        guard let first = text.first, let last = text.last, text.count >= 2 else { return nil }
        for pair in bracketPairs where first == pair.open && last == pair.close {
            let inner = text.dropFirst().dropLast()
            if inner.contains(pair.close) { return nil }
            return String(inner)
        }
        return nil
    }

    /// 같은 본문이 3번 이상 연속이면 첫 조각만 남긴다. 시간 순서로 본다.
    private static func collapseRepeats(_ clips: [SubtitleClip]) -> [SubtitleClip] {
        let ordered = clips.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        var result: [SubtitleClip] = []
        var i = 0
        while i < ordered.count {
            var j = i + 1
            while j < ordered.count, ordered[j].text == ordered[i].text { j += 1 }
            if j - i >= 3 {
                result.append(ordered[i])
            } else {
                result.append(contentsOf: ordered[i..<j])
            }
            i = j
        }
        return result
    }
}
