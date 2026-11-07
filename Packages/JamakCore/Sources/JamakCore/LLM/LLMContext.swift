import Foundation

/// LLM에 보내는 줄 하나. 번호는 자막셋 전체 타임라인 순서의 1부터 번호.
public struct LLMLine: Codable, Equatable, Sendable {
    public var id: String
    /// "03:41.0–03:43.5". 1시간이 넘으면 "h:mm:ss.s".
    public var time: String
    /// speech | screen | sound
    public var kind: String
    /// 작품 원어 칸의 지금 문장.
    public var source: String
    /// 대상 언어 칸(번역·번역 검토에서만).
    public var translation: String?
    /// true = 문맥 줄(대상 아님).
    public var context: Bool?
    /// 사람이 이 조각에 단 주석(확인한 사실). 없으면 nil.
    public var note: String?

    public init(id: String, time: String, kind: String, source: String, translation: String? = nil,
                context: Bool? = nil, note: String? = nil) {
        self.id = id; self.time = time; self.kind = kind; self.source = source
        self.translation = translation; self.context = context; self.note = note
    }
}

public enum LLMContext {
    /// 대상 조각과, 그 앞 `before`줄·뒤 `after`줄(자막셋 전체 타임라인 기준)을 줄로 만든다. 대상 아닌 줄은 context=true.
    public static func lines(set: CueSet, original: Language, translation: Language?,
                             targets: Set<UUID>, before: Int = 10, after: Int = 5) -> [LLMLine] {
        let cues = set.cuesInTimelineOrder
        var included = Set<Int>()
        for (i, cue) in cues.enumerated() where targets.contains(cue.id) {
            included.formUnion(max(0, i - max(0, before))...min(cues.count - 1, i + max(0, after)))
        }
        return included.sorted().map { i in
            let cue = cues[i]
            return LLMLine(id: String(i + 1), time: time(start: cue.start, end: cue.end), kind: cue.kind.rawValue,
                           source: cue.text(original), translation: translation.map { cue.text($0) },
                           context: targets.contains(cue.id) ? nil : true,
                           note: cue.hasNote ? cue.note.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
    }

    /// 줄 범위(첫 줄 시작~마지막 줄 끝)와 겹치는 메모. 프롬프트 칸에 넣을 글. 없으면 "(없음)".
    public static func memoBlock(_ memos: [SceneMemo], covering lines: [LLMLine], in set: CueSet) -> String {
        let cues = cues(of: lines, in: set)
        guard let start = cues.map(\.start).min(), let end = cues.map(\.end).max() else { return "(없음)" }
        return memoText(memos, start: start, end: end)
    }

    /// 시간 범위와 겹치는 메모를 "[시간] 글" 줄로. 없으면 "(없음)".
    static func memoText(_ memos: [SceneMemo], start: Int, end: Int) -> String {
        let hits = memos.filter { $0.start <= end && $0.end >= start }
        guard !hits.isEmpty else { return "(없음)" }
        return hits.map { "\(time(start: $0.start, end: $0.end)) \($0.text)" }.joined(separator: "\n")
    }

    /// 그 줄들에 걸린 열린 티켓 요약("[원문] id 12: [의심] 이유 / 전 → 후", "[번역 ko] id 12: …").
    /// 원문 검토(`translation` nil)면 작품 원어 칸의 티켓만, 번역 검토면 원어 칸과 그 번역 언어 칸의 티켓만 넣는다.
    /// 없으면 "(없음)".
    public static func ticketBlock(_ book: TicketBook, set: CueSet, lines: [LLMLine],
                                   original: Language, translation: Language?) -> String {
        let order = set.cuesInTimelineOrder
        let numbers = Dictionary(order.enumerated().map { ($1.id, String($0 + 1)) }, uniquingKeysWith: { a, _ in a })
        let shown = Set(lines.map(\.id))
        var out: [String] = []
        for ticket in book.tickets(set: set.id) {
            let column: String
            if ticket.language == original {
                column = "원문"
            } else if let translation, ticket.language == translation {
                column = "번역 \(translation.rawValue)"
            } else {
                continue
            }
            let label = ticket.level == .fix ? "고침" : "의심"
            for change in ticket.changes {
                guard let id = numbers[change.cueID], shown.contains(id) else { continue }
                let diff = change.after.isEmpty ? change.before : "\(change.before) → \(change.after)"
                out.append("[\(column)] id \(id): [\(label)] \(ticket.reason) / \(diff)")
            }
        }
        return out.isEmpty ? "(없음)" : out.joined(separator: "\n")
    }

    /// 줄 하나를 프롬프트에 넣을 JSON 한 줄로(키 순서 고정).
    public static func json(_ line: LLMLine) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: (try? encoder.encode(line)) ?? Data(), as: UTF8.self)
    }

    /// 줄 번호 → 조각 id
    public static func cueID(forLineID id: String, in set: CueSet) -> UUID? {
        guard let n = Int(id), n >= 1 else { return nil }
        let cues = set.cuesInTimelineOrder
        return n <= cues.count ? cues[n - 1].id : nil
    }

    private static func cues(of lines: [LLMLine], in set: CueSet) -> [Cue] {
        let order = set.cuesInTimelineOrder
        return lines.compactMap { line in
            guard let n = Int(line.id), n >= 1, n <= order.count else { return nil }
            return order[n - 1]
        }
    }

    /// "03:41.3–03:43.9". 1시간이 넘으면 "1:01:01.0–1:01:02.5".
    static func time(start: Int, end: Int) -> String { "\(stamp(start))–\(stamp(end))" }

    private static func stamp(_ ms: Int) -> String {
        let full = Timecode.tenths(ms)          // HH:MM:SS.s
        if ms >= 3_600_000 {
            let hours = max(0, ms) / 3_600_000
            return "\(hours)" + full.dropFirst(full.prefix(while: { $0 != ":" }).count)
        }
        return String(full.dropFirst(3))
    }
}

public enum WholeRequest {
    /// 한 요청으로 보내고, `LLMError.contextTooLong`이면 겹치는 창으로 나눠 보낸다. 결과는 창 순서대로 이어 붙인다.
    /// 겹치는 줄은 앞 창에서는 대상이고 뒤 창에서는 `context: true`다.
    public static func run<R: Sendable>(lines: [LLMLine], window: Int = 300, overlap: Int = 50,
                                        forceWindows: Bool,
                                        send: @Sendable ([LLMLine]) async throws -> R) async throws -> [R] {
        if !forceWindows {
            do { return [try await send(lines)] } catch LLMError.contextTooLong {}
        }
        let size = max(1, window)
        let step = max(1, size - max(0, min(overlap, size - 1)))
        var results: [R] = []
        var start = 0
        var sentEnd = 0
        while true {
            let end = min(start + size, lines.count)
            var chunk = Array(lines[start..<end])
            for i in 0..<max(0, min(sentEnd - start, chunk.count)) { chunk[i].context = true }
            // 대상 줄이 없는 창(모두 문맥·검토됨)은 보내지 않는다.
            if chunk.contains(where: { $0.context != true }) { results.append(try await send(chunk)) }
            sentEnd = end
            if end >= lines.count { break }
            start += step
        }
        return results
    }
}
