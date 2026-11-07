import Foundation

/// srt 본문의 종류 부호(4.2)를 읽고 쓴다.
///
/// 쓰기: 소리 `[본문]`(본문에 `]`가 있으면 `［본문］`), 화면 `{\an8}「본문」`, 음성은 그대로.
/// 화면·소리는 encode → decode가 어떤 본문이든 그대로 돌아온다.
/// 음성은 부호 없이 쓰므로 본문 자체가 부호 꼴(예: `[포성]`, `「A」`)이면 다른 종류로 읽힌다.
/// decode는 전체 앞뒤 공백을 자르므로 음성 본문의 앞뒤 공백은 남지 않는다.
public enum KindMarkup {
    private static let an8 = "{\\an8}"

    public static func decode(_ raw: String) -> (SubtitleKind, String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(an8) {
            s = String(s.dropFirst(an8.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            // {\an8}가 있으면 화면이 확실하니, 「…」는 바깥 한 쌍만 벗긴다(안쪽 」는 본문이다).
            if s.count >= 2, s.first == "「", s.last == "」" {
                return (.screen, String(s.dropFirst().dropLast()))
            }
            return (.screen, s)
        }
        if let inner = unwrap(s, open: "「", close: "」") {
            return (.screen, inner)
        }
        if let inner = unwrap(s, open: "[", close: "]") {
            return (.sound, inner)
        }
        // ［…］: 안쪽에 ］가 없거나, 안쪽에 ]가 있으면(본문에 ]가 든 소리를 Jamak이 쓰는 꼴) 바깥 한 쌍을 벗긴다.
        if s.count >= 2, s.first == "［", s.last == "］" {
            let inner = String(s.dropFirst().dropLast())
            if !inner.contains("］") || inner.contains("]") { return (.sound, inner) }
        }
        return (.speech, s)
    }

    public static func encode(_ kind: SubtitleKind, _ text: String) -> String {
        switch kind {
        case .speech: return text
        case .sound: return text.contains("]") ? "［\(text)］" : "[\(text)]"
        case .screen: return "\(an8)「\(text)」"
        }
    }

    /// 첫 글자가 여는 부호이고 닫는 부호가 마지막 글자에만 한 번 나올 때만 벗긴다.
    private static func unwrap(_ s: String, open: Character, close: Character) -> String? {
        guard s.count >= 2, s.first == open, s.last == close else { return nil }
        let inner = s.dropFirst().dropLast()
        guard !inner.contains(close) else { return nil }
        return String(inner)
    }
}
