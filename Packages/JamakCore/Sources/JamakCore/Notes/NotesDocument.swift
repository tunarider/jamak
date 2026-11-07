import Foundation

public struct NotesCharacter: Codable, Equatable, Sendable {
    public var name, reading, relation, speech: String
    public init(name: String, reading: String, relation: String, speech: String) {
        self.name = name; self.reading = reading; self.relation = relation; self.speech = speech
    }
}

public struct NotesTerm: Codable, Equatable, Sendable {
    public var term, note: String
    public init(term: String, note: String) { self.term = term; self.note = note }
}

public struct NotesAnalysis: Codable, Equatable, Sendable {
    public var synopsis: String
    public var characters: [NotesCharacter]
    public var terms: [NotesTerm]
    public init(synopsis: String, characters: [NotesCharacter], terms: [NotesTerm]) {
        self.synopsis = synopsis; self.characters = characters; self.terms = terms
    }
}

public struct GuideSpelling: Codable, Equatable, Sendable {
    public var source, target, note: String
    public init(source: String, target: String, note: String) {
        self.source = source; self.target = target; self.note = note
    }
}

/// `pair`는 "화자 → 상대" 형식이다.
public struct GuideSpeech: Codable, Equatable, Sendable {
    public var pair, style: String
    public init(pair: String, style: String) { self.pair = pair; self.style = style }
}

public struct TranslationGuide: Codable, Equatable, Sendable {
    public var spellings: [GuideSpelling]
    public var speech: [GuideSpeech]
    public init(spellings: [GuideSpelling], speech: [GuideSpeech]) {
        self.spellings = spellings; self.speech = speech
    }
}

/// 프로젝트의 `notes.md`. 줄 단위로 다루고, 바꾸는 곳에만 줄을 끼워 넣는다.
public struct NotesDocument: Equatable, Sendable {
    public let markdown: String

    public init(markdown: String) { self.markdown = markdown }

    private enum Columns {
        static let character = ["원문 이름", "읽기", "관계", "말투"]
        static let term = ["용어", "설명"]
        static let spelling = ["원문", "번역", "비고"]
        static let speech = ["화자 → 상대", "말투"]
    }

    public static func template(title: String) -> NotesDocument {
        NotesDocument(markdown: """
        # \(title) 작품 노트

        ## 줄거리

        ## 등장인물
        \(NotesLines.tableHead(Columns.character).joined(separator: "\n"))

        ## 용어집 (원문)
        \(NotesLines.tableHead(Columns.term).joined(separator: "\n"))

        """)
    }

    /// 제목·빈 줄·표 머리(머리 줄과 구분 줄)밖에 없다(틀만 있는 노트). 검토 전에 분석부터 할지 정하는 데 쓴다.
    public var isEmpty: Bool {
        let lines = NotesLines.split(markdown)
        for (i, line) in lines.enumerated() {
            if NotesLines.isBlank(line) || NotesLines.heading(line) != nil || NotesLines.isSeparator(line) { continue }
            if NotesLines.isTableLine(line), i + 1 < lines.count, NotesLines.isSeparator(lines[i + 1]) { continue }
            return false
        }
        return true
    }

    // MARK: 분석 병합

    /// 분석 결과를 더한다. 줄거리는 비어 있을 때만 채운다. 표에는 첫 열(이름·용어)이 없는 행만 덧붙인다.
    public func merging(_ analysis: NotesAnalysis) -> NotesDocument {
        var lines = NotesLines.split(markdown)
        let whole = { (l: [String]) in 0..<l.count }

        let synopsis = analysis.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        if !synopsis.isEmpty {
            let synopsisLines = synopsis.components(separatedBy: "\n")
            if let s = NotesLines.section(lines, in: whole(lines), level: 2, where: { $0 == "줄거리" }) {
                if lines[s.body].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    lines.insert(contentsOf: synopsisLines, at: s.heading + 1)
                }
            } else {
                NotesLines.appendAtEnd(&lines, ["## 줄거리"] + synopsisLines)
            }
        }

        mergeRows(&lines, level: 2, where: { $0 == "등장인물" }, title: "등장인물",
                  columns: Columns.character,
                  rows: analysis.characters.map { [$0.name, $0.reading, $0.relation, $0.speech] })
        mergeRows(&lines, level: 2, where: { $0.hasPrefix("용어집") }, title: "용어집 (원문)",
                  columns: Columns.term,
                  rows: analysis.terms.map { [$0.term, $0.note] })
        return NotesDocument(markdown: NotesLines.join(lines))
    }

    private func mergeRows(_ lines: inout [String], level: Int, where match: (String) -> Bool,
                           title: String, columns: [String], rows: [[String]]) {
        guard !rows.isEmpty else { return }
        if let s = NotesLines.section(lines, in: 0..<lines.count, level: level, where: match) {
            NotesLines.addRows(&lines, body: s.body, columns: columns, rows: rows, createEmpty: false)
        } else {
            let heading = String(repeating: "#", count: level) + " " + title
            NotesLines.appendAtEnd(&lines, [heading])
            if let s = NotesLines.section(lines, in: 0..<lines.count, level: level, where: { $0 == title }) {
                NotesLines.addRows(&lines, body: s.body, columns: columns, rows: rows, createEmpty: false)
            }
        }
    }

    // MARK: 번역 가이드

    /// `## 번역: <languageName>` 섹션을 만들거나 보강한다(표기·말투 표, 같은 규칙).
    public func merging(_ guide: TranslationGuide, languageName: String) -> NotesDocument {
        var lines = NotesLines.split(markdown)
        let name = languageName.trimmingCharacters(in: .whitespacesAndNewlines)
        let find = { (l: [String]) in
            NotesLines.section(l, in: 0..<l.count, level: 2) { NotesLines.translationLanguage($0) == name }
        }
        if find(lines) == nil { NotesLines.appendAtEnd(&lines, ["## 번역: \(name)"]) }

        let parts: [(String, [String], [[String]])] = [
            ("표기", Columns.spelling, guide.spellings.map { [$0.source, $0.target, $0.note] }),
            ("말투", Columns.speech, guide.speech.map { [$0.pair, $0.style] }),
        ]
        for (title, columns, rows) in parts {
            guard let trans = find(lines) else { break }
            if NotesLines.section(lines, in: trans.body, level: 3, where: { $0 == title }) == nil {
                NotesLines.insertBlock(&lines, at: NotesLines.endOfContent(lines, in: trans.body),
                                       ["### \(title)"])
            }
            guard let trans2 = find(lines),
                  let sub = NotesLines.section(lines, in: trans2.body, level: 3, where: { $0 == title })
            else { continue }
            NotesLines.addRows(&lines, body: sub.body, columns: columns, rows: rows, createEmpty: true)
        }
        return NotesDocument(markdown: NotesLines.join(lines))
    }

    /// `## 번역: <languageName>` 섹션의 표기·말투 표를 읽는다. 없으면 빈 값.
    public func guide(languageName: String) -> TranslationGuide {
        let lines = NotesLines.split(markdown)
        let name = languageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trans = NotesLines.section(lines, in: 0..<lines.count, level: 2, where: {
            NotesLines.translationLanguage($0) == name
        }) else { return TranslationGuide(spellings: [], speech: []) }

        func read(_ title: String, _ columns: [String]) -> [[String]] {
            guard let sub = NotesLines.section(lines, in: trans.body, level: 3, where: { $0 == title })
            else { return [] }
            return NotesLines.readRows(lines, body: sub.body, columns: columns)
        }
        return TranslationGuide(
            spellings: read("표기", Columns.spelling).map {
                GuideSpelling(source: $0[0], target: $0[1], note: $0[2])
            },
            speech: read("말투", Columns.speech).map { GuideSpeech(pair: $0[0], style: $0[1]) })
    }

    // MARK: LLM 맥락

    /// LLM 맥락용: 문서 전체(다른 언어의 번역 섹션은 뺀다). `nil`이면 번역 섹션을 모두 뺀다.
    public func context(for languageName: String?) -> String {
        let lines = NotesLines.split(markdown)
        let keep = languageName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if let h = NotesLines.heading(lines[i]), h.level == 2,
               let lang = NotesLines.translationLanguage(h.title), lang != keep {
                i += 1
                while i < lines.count, !(NotesLines.heading(lines[i]).map { $0.level <= 2 } ?? false) { i += 1 }
                continue
            }
            out.append(lines[i])
            i += 1
        }
        return NotesLines.join(out)
    }
}

/// 줄 단위 마크다운 도우미. 모든 인덱스는 `[String]` 줄 배열 기준이다.
private enum NotesLines {
    static func split(_ s: String) -> [String] { s.components(separatedBy: "\n") }
    static func join(_ l: [String]) -> String { l.joined(separator: "\n") }

    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 공백을 모두 뺀 열 이름. 열 이름 비교에 쓴다.
    static func normalize(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    static func tableHead(_ columns: [String]) -> [String] {
        ["| " + columns.joined(separator: " | ") + " |",
         "|" + String(repeating: "---|", count: columns.count)]
    }

    // MARK: 제목과 섹션

    static func heading(_ line: String) -> (level: Int, title: String)? {
        var n = 0
        for c in line { if c == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), line.dropFirst(n).first == " " else { return nil }
        return (n, line.dropFirst(n).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "번역: 한국어" → "한국어". 번역 섹션 제목이 아니면 nil.
    static func translationLanguage(_ title: String) -> String? {
        guard title.hasPrefix("번역:") else { return nil }
        return title.dropFirst("번역:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `range` 안에서 첫 번째로 맞는 `level` 제목과 그 본문 범위(다음 같거나 높은 제목 전까지).
    static func section(_ lines: [String], in range: Range<Int>, level: Int,
                        where match: (String) -> Bool) -> (heading: Int, body: Range<Int>)? {
        var i = range.lowerBound
        while i < range.upperBound {
            if let h = heading(lines[i]), h.level == level, match(h.title) {
                var j = i + 1
                while j < range.upperBound {
                    if let n = heading(lines[j]), n.level <= level { break }
                    j += 1
                }
                return (i, (i + 1)..<j)
            }
            i += 1
        }
        return nil
    }

    // MARK: 삽입

    /// 범위의 마지막 내용 줄 바로 다음 위치. 내용이 없으면 범위 시작.
    static func endOfContent(_ lines: [String], in body: Range<Int>) -> Int {
        var i = body.upperBound
        while i > body.lowerBound, isBlank(lines[i - 1]) { i -= 1 }
        return i
    }

    /// `at`에 블록을 끼워 넣는다. 앞이 글(제목 아님)이면 빈 줄을, 뒤가 글이면 빈 줄을 덧댄다.
    static func insertBlock(_ lines: inout [String], at pos: Int, _ block: [String]) {
        var b = block
        if pos > 0, !isBlank(lines[pos - 1]), heading(lines[pos - 1]) == nil {
            b.insert("", at: 0)
        }
        if pos < lines.count, !isBlank(lines[pos]) { b.append("") }
        lines.insert(contentsOf: b, at: pos)
    }

    /// 문서 끝에 블록을 붙인다. 끝의 개행 모양은 그대로 둔다.
    static func appendAtEnd(_ lines: inout [String], _ block: [String]) {
        var tail = 0
        while let last = lines.last, last.isEmpty, !lines.isEmpty { lines.removeLast(); tail += 1 }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: block)
        lines.append(contentsOf: Array(repeating: "", count: tail))
    }

    // MARK: 표

    static func splitCells(_ line: String) -> [String] {
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var cur = ""
        var i = chars.first == "|" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "|" {
                cur.append("|"); i += 2; continue
            }
            if c == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        if !isBlank(cur) { cells.append(cur.trimmingCharacters(in: .whitespaces)) }
        return cells
    }

    static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    static func isSeparator(_ line: String) -> Bool {
        guard isTableLine(line) else { return false }
        let cells = splitCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    struct Table {
        var header: Int
        var rows: Range<Int>
        var headers: [String]
    }

    /// `key` 열이 있는 첫 표.
    static func findTable(_ lines: [String], in body: Range<Int>, key: String) -> Table? {
        let want = normalize(key)
        var i = body.lowerBound
        while i + 1 < body.upperBound {
            if isTableLine(lines[i]), isSeparator(lines[i + 1]) {
                let headers = splitCells(lines[i])
                if headers.contains(where: { normalize($0) == want }) {
                    var end = i + 2
                    while end < body.upperBound, isTableLine(lines[end]) { end += 1 }
                    return Table(header: i, rows: (i + 2)..<end, headers: headers)
                }
            }
            i += 1
        }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    static func rowLine(_ cells: [String]) -> String {
        "| " + cells.map(escape).joined(separator: " | ") + " |"
    }

    /// 표를 읽어 `columns` 순서의 행으로 돌려준다. 없는 열과 모자란 칸은 빈 문자열. 전부 빈 행은 건너뛴다.
    static func readRows(_ lines: [String], body: Range<Int>, columns: [String]) -> [[String]] {
        guard let t = findTable(lines, in: body, key: columns[0]) else { return [] }
        let map = columns.map { c in t.headers.firstIndex { normalize($0) == normalize(c) } }
        var out: [[String]] = []
        for i in t.rows where !isSeparator(lines[i]) {
            let cells = splitCells(lines[i])
            let row = map.map { idx in idx.flatMap { $0 < cells.count ? cells[$0] : nil } ?? "" }
            if row.contains(where: { !$0.isEmpty }) || cells.contains(where: { !$0.isEmpty }) { out.append(row) }
        }
        return out
    }

    /// 첫 열 값이 없는 행만 표 마지막 행 뒤에 덧붙인다. 표가 없으면 섹션 끝에 머리행과 함께 만든다.
    static func addRows(_ lines: inout [String], body: Range<Int>, columns: [String],
                        rows: [[String]], createEmpty: Bool) {
        let table = findTable(lines, in: body, key: columns[0])
        var seen = Set<String>()
        if let t = table, let keyCol = t.headers.firstIndex(where: { normalize($0) == normalize(columns[0]) }) {
            for i in t.rows {
                let cells = splitCells(lines[i])
                if keyCol < cells.count { seen.insert(cells[keyCol].lowercased()) }
            }
        }
        var fresh: [[String]] = []
        for row in rows {
            let key = row[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty || !seen.insert(key).inserted { continue }
            fresh.append(row)
        }

        if let t = table {
            let map = t.headers.map { h in columns.firstIndex { normalize($0) == normalize(h) } }
            let newLines = fresh.map { row in rowLine(map.map { $0.map { row[$0] } ?? "" }) }
            lines.insert(contentsOf: newLines, at: t.rows.upperBound)
        } else if !fresh.isEmpty || createEmpty {
            let block = tableHead(columns) + fresh.map(rowLine)
            insertBlock(&lines, at: endOfContent(lines, in: body), block)
        }
    }
}
