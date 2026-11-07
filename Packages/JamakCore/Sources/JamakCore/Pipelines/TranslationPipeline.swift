import Foundation

/// 번역 자막 생성(설계 6.3): 원문을 번역만 한다. 검토나 티켓은 없다(검토는 따로 하는 작업이다).
public enum TranslationPipeline {
    // 용어집 응답. 배열이 빠져도 오류가 아니다.
    private struct GlossaryReply: Decodable {
        var spellings: [GuideSpelling]?
        var speech: [GuideSpeech]?
    }

    // 구간 하나의 응답.
    struct Reply: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            var id: String
            var text: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                id = try Flex.id(c, .id)
                text = try? c.decode(String.self, forKey: .text)
            }
            enum Keys: String, CodingKey { case id, text }
        }
        var lines: [Line]?
    }

    /// 구간의 결과(중간 저장에도 이 모양 그대로 둔다). 번역을 받지 못한 조각은 없다.
    struct ChunkResult: Codable, Equatable, Sendable {
        var texts: [UUID: String]
    }

    /// 시도 사이에 맞게 온 줄을 모은다.
    private actor Collector {
        var texts: [UUID: String] = [:]
        func snapshot() -> [UUID: String] { texts }
        func add(_ id: UUID, text: String) {
            if texts[id] == nil { texts[id] = text }
        }
    }

    private static let glossaryTemperature = 0.2
    private static let translationTemperature = 0.3
    private static let lastTry = 2

    /// 노트와 원문(앞 12,000자)을 보고 번역 용어집을 만든다. 노트에 이미 있는 표기·말투는 다시 쓰지 말라고 지시한다.
    /// `sourceLanguage`·`targetLanguage`는 언어 코드(프롬프트에 영어 이름과 함께 쓴다), `languageName`은 노트 섹션 이름이다.
    public static func glossary(
        clips: [SubtitleClip], notes: NotesDocument, sourceLanguage: String, targetLanguage: String,
        languageName: String, text: LLMRole
    ) async throws -> TranslationGuide {
        let sorted = clips.sorted(by: SubtitleClip.timelineOrder)
        let lines = AnalysisPipeline.split(AnalysisPipeline.transcript(sorted)).first ?? []
        // 프롬프트는 시도 밖에서 읽는다: 없는 프롬프트는 재시도 대상이 아니다.
        let prompt = try Prompts.text("glossary", [
            "sourceLanguage": Prompts.languageLabel(sourceLanguage),
            "targetLanguage": Prompts.languageLabel(targetLanguage),
            "notes": notes.context(for: languageName),
            "transcript": lines.joined(separator: "\n"),
        ])
        let results = try await ChunkRunner.run(
            [Chunk(index: 0, items: 0..<1, context: 0..<0)], limit: 1,
            attempt: { _, _ in
                let raw = try await text.client.complete(ChatRequest(
                    model: text.model, messages: [.user(prompt)], temperature: glossaryTemperature))
                let reply = try JSONReply.decode(GlossaryReply.self, from: raw)
                return TranslationGuide(spellings: reply.spellings ?? [], speech: reply.speech ?? [])
            }, onProgress: { _, _ in })
        guard let guide = results.first ?? nil else { throw LLMError.badReply("용어집 응답을 받지 못했어요") }
        return guide
    }

    /// `targets` 조각(순서는 상관없다. 타임라인 순서로 다룬다)을 `original` 칸에서 `target` 칸으로 번역한다.
    /// 40~60줄 구간(`ChunkPlanner`)으로 나눠 병렬로 보낸다. 구간마다 자막셋 전체에서 앞 10줄·뒤 5줄을 문맥으로 넣고,
    /// 문맥 줄에 이미 있는 번역(이번에 다시 번역하는 칸은 빼고)은 `translation`으로 함께 보낸다.
    /// 그 범위와 겹치는 장면 메모와, 대상 줄에 나오는 용어집 표기(`guide`)도 넣는다.
    /// 돌려주는 것은 번역을 받은 조각(조각 id → 문장)이다. 받지 못한 조각은 빠진다.
    /// 구간 진행률은 `onProgress(끝난 구간, 전체)`이다.
    public static func translate(
        set: CueSet, original: Language, target: Language, targets: [UUID],
        notes: NotesDocument, guide: TranslationGuide?, text: LLMRole, concurrency: Int,
        checkpoints: CheckpointStore, onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> [UUID: String] {
        let order = set.cuesInTimelineOrder
        let wanted = Set(targets)
        let clips = order.filter { wanted.contains($0.id) }.map {
            SubtitleClip(id: $0.id, start: $0.start, end: $0.end, kind: $0.kind, text: $0.text(original))
        }
        guard !clips.isEmpty else { return [:] }
        let sorted = clips.sorted(by: SubtitleClip.timelineOrder)
        let chunks = ChunkPlanner.plan(sorted)
        // 줄 번호(자막셋 전체 타임라인 기준 1부터) → 조각
        let cueByLine = Dictionary(order.enumerated().map { (String($0 + 1), $1) }, uniquingKeysWith: { a, _ in a })
        let notesContext = notes.context(for: target.displayName)
        let template = try Prompts.template("translation")
        let fixedValues = [
            "sourceLanguage": Prompts.languageLabel(original.rawValue),
            "targetLanguage": Prompts.languageLabel(target.rawValue),
            "notes": notesContext,
        ]
        let collectors = chunks.map { _ in Collector() }

        /// `pending`을 대상으로 한 줄. 대상 줄에는 번역을 넣지 않는다. 문맥 줄에는 이번에 받은 번역을,
        /// 없으면 다시 번역하지 않는 칸의 이미 있는 번역을 넣는다.
        @Sendable func lines(pending: Set<UUID>, have: [UUID: String]) -> [LLMLine] {
            var lines = LLMContext.lines(set: set, original: original, translation: target, targets: pending)
            for i in lines.indices {
                guard lines[i].context == true, let cue = cueByLine[lines[i].id] else {
                    lines[i].translation = nil
                    continue
                }
                if let got = have[cue.id] {
                    lines[i].translation = got
                } else if wanted.contains(cue.id) || lines[i].translation?.isEmpty != false {
                    lines[i].translation = nil
                }
            }
            return lines
        }

        let results = try await ChunkRunner.run(chunks, limit: concurrency, attempt: { chunk, attemptNo in
            let own = sorted[chunk.items].map(\.id)
            let whole = lines(pending: Set(own), have: [:])
            let memos = LLMContext.memoBlock(set.memos, covering: whole, in: set)
            let hints = glossaryHints(guide, sources: sorted[chunk.items].map(\.text))
            let wholeJSON = whole.map(LLMContext.json)
            // 문맥 줄의 번역과 메모가 바뀌면 다시 보낸다.
            let hash = CheckpointStore.hash(
                [notesContext, original.rawValue, target.rawValue, memos, hints] + wholeJSON)
            if let saved = checkpoints.load(ChunkResult.self, chunk: chunk.index, hash: hash) { return saved }

            let collector = collectors[chunk.index]
            let have = await collector.snapshot()
            let pending = Set(own.filter { have[$0] == nil })
            let sent = have.isEmpty ? wholeJSON : lines(pending: pending, have: have).map(LLMContext.json)
            // 한 번에 채운다: 노트·메모·자막 속 `{{…}}`는 바뀌지 않는다.
            let prompt = Prompts.fill(template, fixedValues.merging([
                "memos": memos, "glossary": hints, "lines": sent.joined(separator: "\n"),
            ], uniquingKeysWith: { _, new in new }))

            let isLast = attemptNo >= lastTry
            var gotReply = true   // 서버 응답을 받았는가(읽을 수 없는 응답 포함)
            do {
                let raw = try await text.client.complete(ChatRequest(
                    model: text.model, messages: [.user(prompt)], temperature: translationTemperature))
                let reply = try JSONReply.decode(Reply.self, from: raw)
                for line in reply.lines ?? [] {
                    // 이번 요청의 대상이 아닌 id는 무시한다.
                    guard let cue = cueByLine[line.id], pending.contains(cue.id) else { continue }
                    let cleaned = JSONReply.cleanText(line.text ?? "", kind: cue.kind)
                    guard !cleaned.isEmpty else { continue }
                    await collector.add(cue.id, text: cleaned)
                }
            } catch let error as LLMError where isLast && error.isRetryable {
                // 마지막 시도에서 응답을 못 읽어도 모아 둔 줄은 버리지 않는다.
                // 읽을 수 없는 응답(badReply)은 응답을 받은 것이고, 5xx·시간 초과는 못 받은 것이다.
                if case .badReply = error {} else { gotReply = false }
            }

            let after = await collector.snapshot()
            let missing = own.filter { after[$0] == nil }
            if !missing.isEmpty, !isLast {
                throw LLMError.badReply("번역이 빠진 줄이 \(missing.count)개 있어요")
            }
            let result = ChunkResult(texts: after)
            // 통신 오류로 끝난 구간은 저장하지 않는다: 다시 돌리면 다시 보낸다.
            if gotReply { try checkpoints.save(result, chunk: chunk.index, hash: hash) }
            return result
        }, onProgress: onProgress)

        var out: [UUID: String] = [:]
        for result in results {
            guard let result else { continue }   // 마지막 시도가 오류를 삼키므로 닿지 않지만, 타입상 남겨 둔다
            out.merge(result.texts.filter { wanted.contains($0.key) }, uniquingKeysWith: { a, _ in a })
        }
        return out
    }

    /// 대상 줄의 원문에 나오는 용어집 표기("田中 → 다나카 (비고)" 줄). 없으면 "(없음)".
    static func glossaryHints(_ guide: TranslationGuide?, sources: [String]) -> String {
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        let hits = (guide?.spellings ?? []).filter { term in
            !term.source.isEmpty && !term.target.isEmpty
                && sources.contains { $0.range(of: term.source, options: options) != nil }
        }
        guard !hits.isEmpty else { return "(없음)" }
        return hits.map { $0.note.isEmpty ? "\($0.source) → \($0.target)" : "\($0.source) → \($0.target) (\($0.note))" }
            .joined(separator: "\n")
    }
}
