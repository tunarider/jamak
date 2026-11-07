import Foundation

/// 한 역할(분석·교정·번역)에 쓰는 LLM 클라이언트와 모델 이름.
public struct LLMRole: Sendable {
    public var client: ChatCompleting
    public var model: String
    public init(client: ChatCompleting, model: String) {
        self.client = client
        self.model = model
    }
}

public enum AnalysisPipeline {
    private struct Synopsis: Decodable { var synopsis: String }

    /// 원문을 12,000자 단위로 나눠 구간별로 분석하고 합친다.
    /// 구간이 둘 이상이면 줄거리는 analysis-merge로 하나로 만들고, 인물·용어는 첫 열 기준으로 중복을 뺀다(먼저 나온 것 우선).
    public static func run(
        clips: [SubtitleClip], notes: NotesDocument, sourceLanguage: String, memos: [SceneMemo] = [], text: LLMRole,
        concurrency: Int, checkpoints: CheckpointStore,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> NotesAnalysis {
        // 원문은 타임라인 순서로 넘긴다(자막셋 배열은 대사 뒤에 소리·화면 조각이 붙어 있을 수 있다).
        let ordered = clips.sorted(by: SubtitleClip.timelineOrder)
        let lines = transcript(ordered)
        let ranges = splitRanges(lines)
        let parts = ranges.map { Array(lines[$0]) }
        // 구간마다 겹치는 메모를 고르기 위해 구간의 시간 범위(첫 조각 시작~가장 늦은 끝)를 둔다.
        let spans = ranges.map { r in
            (start: ordered[r].map(\.start).min() ?? 0, end: ordered[r].map(\.end).max() ?? 0)
        }
        let partMemos = spans.map { LLMContext.memoText(memos, start: $0.start, end: $0.end) }
        let allMemos = LLMContext.memoText(memos, start: Int.min, end: Int.max)
        // 프롬프트는 시도 밖에서 읽는다: 없는 프롬프트는 재시도 대상이 아니다.
        let notesContext = notes.context(for: nil)

        let chunks = parts.indices.map { Chunk(index: $0, items: $0..<$0 + 1, context: $0..<$0) }
        let chunkTemplate = try Prompts.template("analysis-chunk")
        let languageLabel = Prompts.languageLabel(sourceLanguage)
        let results = try await ChunkRunner.run(chunks, limit: concurrency, attempt: { chunk, _ in
            let lines = parts[chunk.index]
            // 언어와 기존 노트가 바뀌면 저장본을 쓰지 않도록 해시에 함께 넣는다.
            let hash = CheckpointStore.hash([sourceLanguage, notesContext, partMemos[chunk.index]] + lines)
            if let saved = checkpoints.load(NotesAnalysis.self, chunk: chunk.index, hash: hash) { return saved }
            // 한 번에 채운다: 노트·메모·자막 속 `{{…}}`는 바뀌지 않는다.
            let prompt = Prompts.fill(chunkTemplate, [
                "language": languageLabel, "notes": notesContext, "memos": partMemos[chunk.index],
                "transcript": lines.joined(separator: "\n"),
            ])
            let reply = try await text.client.complete(ChatRequest(
                model: text.model, messages: [.user(prompt)], temperature: 0.2))
            let analysis = try JSONReply.decode(NotesAnalysis.self, from: reply)
            try checkpoints.save(analysis, chunk: chunk.index, hash: hash)
            return analysis
        }, onProgress: onProgress)

        let analyses = results.compactMap { $0 }
        guard !analyses.isEmpty else { throw LLMError.badReply("분석 응답을 받지 못했어요") }

        let synopses = analyses.map { $0.synopsis.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var synopsis = synopses.joined(separator: "\n\n")
        if synopses.count >= 2 {
            let numbered = synopses.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
            let prompt = try Prompts.text("analysis-merge", ["memos": allMemos, "synopses": numbered])
            let merged = try await ChunkRunner.run(
                [Chunk(index: 0, items: 0..<1, context: 0..<0)], limit: 1,
                attempt: { _, _ in
                    let reply = try await text.client.complete(ChatRequest(
                        model: text.model, messages: [.user(prompt)], temperature: 0.2))
                    let value = try JSONReply.decode(Synopsis.self, from: reply).synopsis
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { throw LLMError.badReply("줄거리가 비었어요") }
                    return value
                }, onProgress: { _, _ in })
            if let value = merged.first ?? nil { synopsis = value }
        }

        var seenNames = Set<String>(), seenTerms = Set<String>()
        let characters = analyses.flatMap(\.characters).filter {
            seenNames.insert($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
        }
        let terms = analyses.flatMap(\.terms).filter {
            seenTerms.insert($0.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
        }
        return NotesAnalysis(synopsis: synopsis, characters: characters, terms: terms)
    }

    /// "[HH:MM:SS] 본문" 줄들. 종류 부호는 KindMarkup으로 붙이고, 본문 속 줄바꿈은 공백으로 바꾼다.
    static func transcript(_ clips: [SubtitleClip]) -> [String] {
        clips.map { clip in
            let stamp = String(Timecode.full(clip.start).prefix(8))
            let body = clip.text.components(separatedBy: .newlines).joined(separator: " ")
            return "[\(stamp)] \(KindMarkup.encode(clip.kind, body))"
        }
    }

    /// 줄을 자르지 않고 글자 수가 `limit`을 넘지 않게 묶는다(줄바꿈 1자 포함). 한 줄이 한도보다 길면 그 줄만으로 한 구간이다.
    static func split(_ lines: [String], limit: Int = 12_000) -> [[String]] {
        splitRanges(lines, limit: limit).map { Array(lines[$0]) }
    }

    /// `split`과 같은 묶음을 줄 번호 범위로 돌려준다.
    static func splitRanges(_ lines: [String], limit: Int = 12_000) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var first = 0
        var size = 0
        for (i, line) in lines.enumerated() {
            let cost = line.count + 1
            if i > first, size + cost > limit {
                out.append(first..<i)
                first = i
                size = 0
            }
            size += cost
        }
        if first < lines.count { out.append(first..<lines.count) }
        return out
    }
}
