import Foundation

public enum JSONReply {
    /// 코드 펜스를 벗기고, 첫 `{`부터 짝이 맞는 `}`까지를 디코드한다. 실패하면 LLMError.badReply.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let json = firstObject(in: stripFence(text)) else {
            throw LLMError.badReply("JSON을 찾지 못했어요")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw LLMError.badReply("JSON을 읽지 못했어요: \(error.localizedDescription)")
        }
    }

    /// 종류 부호로 전체가 감싸진 본문이면 벗기고 앞뒤 공백을 지운다.
    /// 화면은 `{\an8}`와 「」(둘 중 하나 또는 둘 다), 소리는 []·［］, 음성은 공백만 지운다.
    public static func cleanText(_ text: String, kind: SubtitleKind) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .speech:
            break
        case .sound:
            s = unwrap(s, "[", "]") ?? unwrap(s, "［", "］") ?? s
        case .screen:
            let an8 = "{\\an8}"
            if s.hasPrefix(an8) {
                s = String(s.dropFirst(an8.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            s = unwrap(s, "「", "」") ?? s
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrap(_ s: String, _ open: Character, _ close: Character) -> String? {
        guard s.count >= 2, s.first == open, s.last == close else { return nil }
        return String(s.dropFirst().dropLast())
    }

    /// ```json … ``` 펜스가 있으면 그 안쪽만 돌려준다.
    private static func stripFence(_ text: String) -> String {
        guard let open = text.range(of: "```") else { return text }
        var rest = text[open.upperBound...]
        // 여는 펜스 줄의 언어 표시(json 등)를 버린다.
        if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
        if let close = rest.range(of: "```") { rest = rest[..<close.lowerBound] }
        return String(rest)
    }

    /// 첫 `{`부터 문자열 안의 괄호를 무시하며 짝이 맞는 `}`까지.
    private static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
