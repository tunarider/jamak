import Foundation

/// 화면에 보이는 시간 표기.
public enum Timecode {
    /// `HH:MM:SS.mmm`
    public static func full(_ ms: Int) -> String {
        let ms = max(0, ms)
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// `HH:MM:SS.s`(0.1초 아래는 버림). 타임라인 구간 칩에 쓴다.
    public static func tenths(_ ms: Int) -> String {
        let ms = max(0, ms)
        return String(format: "%02d:%02d:%02d.%d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000 / 100)
    }

    /// `H:MM:SS` 또는 `M:SS`
    public static func short(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `[[H:]MM:]SS[.mmm]`을 밀리초로. 소수점은 `,`도 받는다.
    /// 분·초는 60 미만, 밀리초는 1~3자리, 시는 `maxHours` 이하(Int 오버플로 방지). 숫자만 받는다(부호 불가). 잘못된 입력이면 nil.
    public static func parse(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let secondParts = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondParts.count),
              let seconds = number(secondParts[0]), seconds < 60 else { return nil }
        var ms = 0
        if secondParts.count == 2 {
            let frac = secondParts[1]
            guard (1...3).contains(frac.count), let value = number(frac) else { return nil }
            ms = value * [100, 10, 1][frac.count - 1]
        }
        var total = seconds * 1000 + ms
        let higher = Array(parts.dropLast())
        if let minutesPart = higher.last {
            guard let minutes = number(minutesPart), minutes < 60 else { return nil }
            total += minutes * 60_000
        }
        if higher.count == 2 {
            guard let hours = number(higher[0]), hours <= maxHours else { return nil }
            total += hours * 3_600_000
        }
        return total
    }

    static let maxHours = 99_999

    private static func number(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }
}
