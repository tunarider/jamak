import Foundation

public enum SRTCodec {
    private static let minDuration = 300

    public static func parse(_ data: Data) -> [SubtitleClip] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = text.components(separatedBy: "\n")
        var timeLines: [(index: Int, start: Int, end: Int)] = []
        for (i, line) in lines.enumerated() {
            if let t = parseTimeLine(line) { timeLines.append((i, t.0, t.1)) }
        }

        var clips: [SubtitleClip] = []
        for (n, t) in timeLines.enumerated() {
            let isLast = n == timeLines.count - 1
            let upper = isLast ? lines.count : timeLines[n + 1].index
            var body = Array(lines[(t.index + 1)..<upper])
            trimTrailingBlank(&body)
            if !isLast, body.count >= 2,
               isNumber(body[body.count - 1]), body[body.count - 2].trimmingCharacters(in: .whitespaces).isEmpty {
                body.removeLast()
                trimTrailingBlank(&body)
            }
            while let f = body.first, f.trimmingCharacters(in: .whitespaces).isEmpty { body.removeFirst() }
            let (kind, decoded) = KindMarkup.decode(body.joined(separator: "\n"))
            let end = t.end > t.start ? t.end : t.start + minDuration
            clips.append(SubtitleClip(start: t.start, end: end, kind: kind, text: decoded))
        }
        return clips
    }

    public static func serialize(_ clips: [SubtitleClip]) -> String {
        let sorted = clips.enumerated().sorted {
            $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset
        }.map(\.element)
        return sorted.enumerated().map { i, c in
            "\(i + 1)\n\(format(c.start)) --> \(format(c.end))\n\(KindMarkup.encode(c.kind, c.text))\n"
        }.joined(separator: "\n")
    }

    private static func trimTrailingBlank(_ lines: inout [String]) {
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    }

    private static func isNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func format(_ ms: Int) -> String {
        let v = max(0, ms)
        return String(format: "%02d:%02d:%02d,%03d", v / 3_600_000, v / 60_000 % 60, v / 1000 % 60, v % 1000)
    }

    /// 줄마다 새로 만들면 1,500조각 파일에서 수십 ms가 든다. 한 번만 만든다.
    private static let timeRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"(\d+):(\d{2}):(\d{2})[,.](\d{1,3})"#)
        } catch {
            fatalError("invalid time pattern: \(error)")
        }
    }()

    private static func parseTimeLine(_ line: String) -> (Int, Int)? {
        guard line.contains("-->") else { return nil }
        let regex = timeRegex
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return nil }
        func ms(_ m: NSTextCheckingResult) -> Int? {
            guard let h = Int(ns.substring(with: m.range(at: 1))),
                  let mi = Int(ns.substring(with: m.range(at: 2))),
                  let s = Int(ns.substring(with: m.range(at: 3))) else { return nil }
            var frac = ns.substring(with: m.range(at: 4))
            while frac.count < 3 { frac += "0" }
            guard let f = Int(frac) else { return nil }
            return ((h * 60 + mi) * 60 + s) * 1000 + f
        }
        guard let a = ms(matches[0]), let b = ms(matches[1]) else { return nil }
        return (a, b)
    }
}
