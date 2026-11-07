import Foundation

/// 원문 검토(설계 6.4)와 번역 검토(6.5). 응답을 티켓으로 바꿔 돌려준다.
public enum ReviewPipeline {
    public enum Kind: Sendable {
        case source
        case translation(Language)
    }

    /// 용어집 규칙 검사 결과 하나(번역 검토 프롬프트의 단서).
    public struct GlossaryIssue: Equatable, Sendable {
        public var cueID: UUID
        public var reason: String
        public init(cueID: UUID, reason: String) { self.cueID = cueID; self.reason = reason }
    }

    private static let temperature = 0.2
    private static let attempts = 3

    /// targets == nil이면 자막셋 전체(한 요청, 넘치면 창). 아니면 그 조각과 앞 10·뒤 5줄.
    /// `skipReviewed`(전체·구간 검토): 검토할 언어 칸이 검토됨인 조각은 대상에서 빼고 문맥으로만 보내며,
    /// 검토됨 칸에 난 티켓은 버린다. 조각 검토는 false다.
    /// `userLanguage`가 작품 원어와 다르면 원문 검토 티켓에 바꾸기 전·후 문장의 뜻을 그 언어로 받는다.
    /// 번역 검토는 번역 칸만 본다: 원문 티켓은 내지 않는다(원문 문제는 원문 검토에서 잡는다).
    /// `instruction`(지시 검토): 사용자가 쓴 지시문. 있으면 그 지시에 맞는 곳만 찾아 고치게 한다.
    /// 돌려준 티켓은 아직 열지 않은 것이다(앱이 editor.open으로 연다).
    public static func run(kind: Kind, set: CueSet, original: Language, targets: Set<UUID>?,
                           notes: NotesDocument, tickets: TicketBook, guide: TranslationGuide?,
                           text: LLMRole, forceWindows: Bool, skipReviewed: Bool = false,
                           userLanguage: Language? = nil, instruction: String? = nil) async throws -> [Ticket] {
        let target: Language? = if case .translation(let language) = kind { language } else { nil }
        let reviewLanguage = target ?? original
        let skipped: Set<UUID> = skipReviewed
            ? Set(set.cues.filter { $0.reviewed.contains(reviewLanguage) }.map(\.id)) : []
        let lines: [LLMLine]
        if let targets {
            lines = LLMContext.lines(set: set, original: original, translation: target,
                                     targets: targets.subtracting(skipped))
        } else {
            let numbers = lineNumbers(set)
            let skippedLines = Set(skipped.compactMap { numbers[$0] })
            lines = LLMContext.lines(set: set, original: original, translation: target,
                                     targets: Set(set.cues.map(\.id)), before: 0, after: 0)
                .map { line in
                    var line = line
                    if skippedLines.contains(line.id) { line.context = true }
                    return line
                }
        }
        guard lines.contains(where: { $0.context != true }) else { return [] }
        let reviewedCells: Set<TicketBook.Cell> = skipReviewed
            ? Set(set.cues.flatMap { cue in cue.reviewed.map { TicketBook.Cell(cue: cue.id, language: $0) } }) : []
        let meaning = target == nil ? userLanguage.flatMap { $0 == original ? nil : $0 } : nil

        // 프롬프트는 요청 밖에서 읽는다: 창마다 줄·메모·티켓·단서만 바꾼다.
        let template: String
        var fixed: [String: String]
        var hints: [String: String] = [:]   // 줄 id → 용어집 단서
        if let target {
            template = try Prompts.template("translation-review")
            fixed = [
                "sourceLanguage": Prompts.languageLabel(original.rawValue),
                "targetLanguage": Prompts.languageLabel(target.rawValue),
                "notes": notes.context(for: target.displayName),
            ]
            if let guide {
                let numbers = lineNumbers(set)
                for issue in glossaryIssues(set: set, original: original, target: target, guide: guide) {
                    if let id = numbers[issue.cueID] { hints[id] = issue.reason }
                }
            }
        } else {
            template = try Prompts.template("source-review")
            fixed = [
                "language": Prompts.languageLabel(original.rawValue), "notes": notes.context(for: nil),
                "meaningRule": meaning.map { meaningRule(original: original, user: $0) } ?? "",
                "meaningFields": meaning == nil ? "" : meaningFields,
            ]
        }
        fixed["instruction"] = instructionBlock(instruction)
        let fixedHints = hints
        let fixedValues = fixed

        let replies = try await WholeRequest.run(lines: lines, forceWindows: forceWindows) { window in
            let own = window.filter { $0.context != true }.map(\.id)
            let hintText = own.compactMap { id in fixedHints[id].map { "id \(id): \($0)" } }
            // 한 번에 채운다: 노트·메모·자막 속 `{{…}}`는 바뀌지 않는다.
            let prompt = Prompts.fill(template, fixedValues.merging([
                "memos": LLMContext.memoBlock(set.memos, covering: window, in: set),
                "tickets": LLMContext.ticketBlock(tickets, set: set, lines: window,
                                                  original: original, translation: target),
                "glossaryHints": hintText.isEmpty ? "(없음)" : hintText.joined(separator: "\n"),
                "lines": window.map(LLMContext.json).joined(separator: "\n"),
            ], uniquingKeysWith: { _, new in new }))
            let reply = try await ask(prompt, text: text)
            return (targets: Set(own), reply: reply)
        }

        return makeTickets(replies, kind: kind, set: set, original: original, open: tickets,
                           skipping: reviewedCells, meanings: meaning != nil)
    }

    /// 지시 검토의 지시 블록. 지시가 없거나 비었으면 "". 빈 줄로 끝난다("찾을 것" 앞에 붙는다).
    static func instructionBlock(_ instruction: String?) -> String {
        let text = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return """
        사용자 지시(이번 검토의 목적)
        --- 지시 시작 ---
        \(text)
        --- 지시 끝 ---
        - 이번 검토는 위 지시를 따르는 것만 합니다. 아래 "찾을 것"은 지시를 해석하는 참고로만 쓰고, 지시와 상관없는 문제는 티켓으로 내지 마세요.
        - 지시에 해당하는 줄을 검토 대상 줄에서 빠짐없이 찾으세요. 여러 줄이 같은 지시에 걸리면 한 티켓의 changes에 모두 넣어도 됩니다.
        - 지시대로 고친 문장이 하나로 정해지면 fix로 내세요. 지시를 어떻게 적용할지 애매하면 suspect로 내고 가장 그럴듯한 후보를 text에 쓰세요.
        - 지시가 작품 노트, 용어집, 주석과 달라도 이번에는 지시를 따르세요.
        - reason에는 어떤 지시를 어떻게 적용했는지 짧게 쓰세요.


        """
    }

    /// 프롬프트의 응답 모양에 덧붙는 뜻 필드.
    static let meaningFields = #","meaningBefore":"…","meaningAfter":"…""#

    /// 원문 검토 티켓에 뜻을 함께 쓰라는 지시. 빈 줄로 끝난다(프롬프트의 규칙 목록 뒤에 붙는다).
    static func meaningRule(original: Language, user: Language) -> String {
        return """
        사용자를 위한 뜻 풀이
        - 사용자는 \(Prompts.languageLabel(original.rawValue))를 잘 몰라 원문 제안만으로는 무엇이 달라지는지 알 수 없어요.
        - changes의 줄마다 meaningBefore에는 지금 문장의 뜻을, meaningAfter에는 제안 문장의 뜻을 \(Prompts.languageLabel(user.rawValue))로 쓰세요.
        - 두 뜻을 나란히 놓았을 때 달라진 점이 드러나게 같은 어휘와 어순으로 옮기세요. 다듬지 말고 원문에 가깝게 옮기세요.
        - 제안 문장이 없으면 meaningAfter는 빈 문자열로 두세요.


        """
    }

    /// LLM 없음. 원어 칸에 용어 원문이 있는데 번역 칸에 지정 표기가 없으면 단서다(번역이 빈 칸은 보지 않는다).
    /// 이유: "용어집: <원문>은(는) <번역>(으)로 옮기기로 했어요". 한 조각에 여럿이면 " / "로 잇는다(용어집 순서).
    /// 결과는 타임라인 순서.
    public static func glossaryIssues(set: CueSet, original: Language, target: Language,
                                      guide: TranslationGuide) -> [GlossaryIssue] {
        let terms = guide.spellings.filter { $0.source.count >= 2 && !$0.target.isEmpty }
        guard !terms.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
        return set.cuesInTimelineOrder.compactMap { cue in
            let source = cue.text(original), translated = cue.text(target)
            guard !source.isEmpty, !translated.isEmpty else { return nil }
            let reasons = terms.filter { term in
                source.range(of: term.source, options: options) != nil
                    && translated.range(of: term.target, options: options) == nil
            }.map { "용어집: \($0.source)은(는) \($0.target)(으)로 옮기기로 했어요" }
            return reasons.isEmpty ? nil : GlossaryIssue(cueID: cue.id, reason: reasons.joined(separator: " / "))
        }
    }

    // MARK: 응답

    struct Reply: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            var level: String?
            var reason: String?
            var target: String?
            var changes: [Change]
            enum Keys: String, CodingKey { case level, reason, target, changes }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                level = try? c.decodeIfPresent(String.self, forKey: .level)
                reason = try? c.decodeIfPresent(String.self, forKey: .reason)
                target = try? c.decodeIfPresent(String.self, forKey: .target)
                changes = (try c.decodeIfPresent([Lossy<Change>].self, forKey: .changes) ?? []).compactMap(\.value)
            }
        }
        struct Change: Decodable, Sendable {
            var id: String
            var text: String
            var meaningBefore: String
            var meaningAfter: String
            enum Keys: String, CodingKey { case id, text, meaningBefore, meaningAfter }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                id = try Flex.id(c, .id)
                text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
                meaningBefore = (try? c.decodeIfPresent(String.self, forKey: .meaningBefore)) ?? ""
                meaningAfter = (try? c.decodeIfPresent(String.self, forKey: .meaningAfter)) ?? ""
            }
        }
        var tickets: [Item]
        enum Keys: String, CodingKey { case tickets }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            tickets = try c.decode([Lossy<Item>].self, forKey: .tickets).compactMap(\.value)
        }
    }

    /// 다시 시도할 수 있는 오류(깨진 응답 등)는 몇 번 더 보낸다. 문맥 길이 초과는 바로 던져 창으로 나누게 한다.
    private static func ask(_ prompt: String, text: LLMRole) async throws -> Reply {
        var tries = 0
        while true {
            tries += 1
            do {
                let raw = try await text.client.complete(ChatRequest(
                    model: text.model, messages: [.user(prompt)], temperature: temperature))
                return try JSONReply.decode(Reply.self, from: raw)
            } catch let error as LLMError where error.isRetryable && tries < attempts {
                try Task.checkCancellation()
            }
        }
    }

    /// 응답 → 티켓. 대상 아닌 줄·없는 id·열린 티켓이 있는 칸·이 검토에서 먼저 잡힌 칸은 버린다.
    /// 고침은 지금과 다른 제안이 있어야 한다(없거나 같으면 버린다). 의심은 제안이 없어도 되고,
    /// 지금 문장을 그대로 돌려준 의심은 제안 없는 의심(`after` "")으로 둔다.
    /// `skipping` 칸(검토됨)은 버린다. `meanings`면 원문 칸 티켓에 뜻 풀이를 남긴다(제안이 없으면 meaningAfter는 비운다).
    static func makeTickets(_ replies: [(targets: Set<String>, reply: Reply)], kind: Kind, set: CueSet,
                            original: Language, open: TicketBook, skipping: Set<TicketBook.Cell> = [],
                            meanings: Bool = false) -> [Ticket] {
        let order = set.cuesInTimelineOrder
        var claimed = Set<TicketBook.Cell>()
        var out: [Ticket] = []
        for (targets, reply) in replies {
            for item in reply.tickets {
                let origin: Ticket.Origin
                let language: Language
                switch kind {
                case .source:
                    (origin, language) = (.source, original)
                case .translation(let target):
                    // 번역 검토는 원문을 고치지 않는다. 원문을 겨눈 티켓은 버린다.
                    if item.target?.trimmingCharacters(in: .whitespaces).lowercased() == "source" { continue }
                    (origin, language) = (.translation, target)
                }
                let level: Ticket.Level = item.level?.trimmingCharacters(in: .whitespaces).lowercased() == "fix"
                    ? .fix : .suspect

                var picked: [(position: Int, change: TicketChange)] = []
                for change in item.changes {
                    guard targets.contains(change.id), let n = Int(change.id), n >= 1, n <= order.count else { continue }
                    let cue = order[n - 1]
                    let cell = TicketBook.Cell(cue: cue.id, language: language)
                    guard !claimed.contains(cell), !skipping.contains(cell),
                          open.ticket(set: set.id, cue: cue.id, language: language) == nil
                    else { continue }
                    let before = cue.text(language)
                    var after = JSONReply.cleanText(change.text, kind: cue.kind)
                    // 의심이 지금 문장을 그대로 돌려주면 제안 없는 의심으로 둔다. 고침은 다른 문장이 있어야 한다.
                    if after == before { after = "" }
                    if after.isEmpty && level == .fix { continue }
                    claimed.insert(cell)
                    var made = TicketChange(cueID: cue.id, before: before, after: after)
                    if meanings && language == original {
                        made.meaningBefore = change.meaningBefore.trimmingCharacters(in: .whitespacesAndNewlines)
                        made.meaningAfter = after.isEmpty ? ""
                            : change.meaningAfter.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    picked.append((n, made))
                }
                guard !picked.isEmpty else { continue }
                out.append(Ticket(setID: set.id, origin: origin, language: language, level: level,
                                  reason: (item.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  changes: picked.sorted { $0.position < $1.position }.map(\.change)))
            }
        }
        return out
    }

    // MARK: 도우미

    private static func lineNumbers(_ set: CueSet) -> [UUID: String] {
        Dictionary(set.cuesInTimelineOrder.enumerated().map { ($1.id, String($0 + 1)) },
                   uniquingKeysWith: { first, _ in first })
    }
}
