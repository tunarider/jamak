import Foundation

/// 단어 타임스탬프로 세그먼트 시간을 다듬는다.
/// - 시작·끝을 첫·마지막 단어에 맞춰 앞뒤 무음을 덜어 낸다.
/// - 단어 사이가 길게 비면(또는 문장 끝 뒤 조금 비면) 거기서 나눠, 한 세그먼트에 뭉친 대사를 푼다.
/// - 자막이 말보다 늦게 뜨거나 끝 글자에서 끊겨 보이지 않게 앞뒤를 조금 늘린다(이웃과 겹치지 않게).
/// 단어가 없는 세그먼트는 그대로 둔다(예전 방식 결과도 같게 나온다).
public enum TranscriptRefiner {
    /// 이만큼 비면 나눈다(초).
    static let pauseSplit = 0.5
    /// 문장 끝(。！？ 등) 뒤로 이만큼 비면 나눈다(초).
    static let sentenceSplit = 0.2
    /// 나눈 양쪽에 글자(문장부호·공백 빼고)가 이만큼은 있어야 나눈다.
    static let minPieceCharacters = 2
    /// 시작을 앞당기는 양(초).
    static let leadIn = 0.05
    /// 끝을 늘리는 양(초).
    static let tailOut = 0.2

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", ".", "．", "…"]

    public static func refine(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard segments.contains(where: { !$0.words.isEmpty }) else { return segments }
        var pieces: [(segment: TranscriptSegment, padded: Bool)] = []
        for segment in segments {
            let words = segment.words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !words.isEmpty else {
                pieces.append((segment, false))
                continue
            }
            for group in split(words) {
                var piece = segment
                piece.words = group
                piece.text = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                piece.startSeconds = group[0].startSeconds
                piece.endSeconds = max(group[group.count - 1].endSeconds, group[0].startSeconds)
                pieces.append((piece, true))
            }
        }
        pieces.sort { $0.segment.startSeconds < $1.segment.startSeconds }
        return pad(pieces)
    }

    /// 단어들을 쉼에서 나눈다. 양쪽 모두 `minPieceCharacters` 이상일 때만 나눈다.
    static func split(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        let counts = words.map { characterCount($0.text) }
        let total = counts.reduce(0, +)
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = [words[0]]
        var currentCount = counts[0]
        var used = 0
        for i in words.indices.dropFirst() {
            let gap = words[i].startSeconds - words[i - 1].endSeconds
            let endsSentence = words[i - 1].text.trimmingCharacters(in: .whitespacesAndNewlines).last
                .map { sentenceEnds.contains($0) } ?? false
            let wantsSplit = gap >= pauseSplit || (endsSentence && gap >= sentenceSplit)
            let rest = total - used - currentCount
            if wantsSplit, currentCount >= minPieceCharacters, rest >= minPieceCharacters {
                groups.append(current)
                used += currentCount
                current = []
                currentCount = 0
            }
            current.append(words[i])
            currentCount += counts[i]
        }
        groups.append(current)
        return groups
    }

    /// 다듬은 조각의 앞뒤를 조금 늘린다. 원래 이웃과 겹치지 않던 자리만 이웃 직전까지 늘린다.
    private static func pad(_ pieces: [(segment: TranscriptSegment, padded: Bool)]) -> [TranscriptSegment] {
        var out = pieces.map(\.segment)
        for i in out.indices where pieces[i].padded {
            let raw = pieces[i].segment
            var start = max(0, raw.startSeconds - leadIn)
            if i > 0 { start = max(start, min(raw.startSeconds, out[i - 1].endSeconds)) }
            var end = raw.endSeconds + tailOut
            if i + 1 < out.count {
                let next = pieces[i + 1].segment
                let nextStart = pieces[i + 1].padded ? next.startSeconds - leadIn : next.startSeconds
                end = min(end, max(raw.endSeconds, nextStart))
            }
            out[i].startSeconds = start
            out[i].endSeconds = end
        }
        return out
    }

    private static func characterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count
    }
}
