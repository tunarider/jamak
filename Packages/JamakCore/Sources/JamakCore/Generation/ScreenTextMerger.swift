import Foundation

/// 글줄이 화면에서 차지하는 자리. 영상 크기에 대한 비율(0...1)이고 원점은 왼쪽 위다.
public struct TextBox: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var midY: Double { y + height / 2 }
}

public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var confidence: Float
    /// 화면 위치. 모르면 nil(인식한 순서를 그대로 쓴다).
    public var box: TextBox?

    public init(text: String, confidence: Float, box: TextBox? = nil) {
        self.text = text
        self.confidence = confidence
        self.box = box
    }
}

public struct FrameText: Equatable, Sendable {
    public var second: Int
    public var lines: [RecognizedLine]

    public init(second: Int, lines: [RecognizedLine]) {
        self.second = second
        self.lines = lines
    }
}

public enum ScreenTextMerger {
    /// 프레임별 OCR 결과로 화면 글자 조각을 만든다. 한 프레임의 글줄은 조각 하나로 합치고(왼쪽 위 → 오른쪽 아래),
    /// 이어지는 프레임이 같은 화면이면(글줄 절반 이상이 같으면) 한 조각으로 잇는다. 그래서 조각끼리 시간이 겹치지 않는다.
    /// 3초 이상 글자가 없으면 끊는다(빈 프레임 1개까지는 이어진 것으로 본다).
    public static func clips(from frames: [FrameText], minConfidence: Float = 0.5, offsetMs: Int = 0) -> [SubtitleClip] {
        struct Screen {
            var keys: Set<String>
            var text: String
            /// `text`의 글줄 수. 같은 화면에서 글줄이 가장 많이 보인 때의 글을 쓴다.
            var lineCount: Int
            var first: Int
            var last: Int
        }
        var open: Screen?
        var finished: [Screen] = []

        for frame in frames.sorted(by: { $0.second < $1.second }) {
            if let screen = open, frame.second - screen.last >= 3 {
                finished.append(screen)
                open = nil
            }
            let rows = readingOrder(usable(frame.lines, minConfidence: minConfidence))
            let lines = rows.flatMap { $0 }
            guard !lines.isEmpty else { continue }
            let keys = Set(lines.map { normalize($0.text) })
            let text = joined(rows)
            if var screen = open, isSameScreen(screen.keys, keys) {
                screen.last = frame.second
                screen.keys.formUnion(keys)
                if lines.count > screen.lineCount {
                    screen.text = text
                    screen.lineCount = lines.count
                }
                open = screen
            } else {
                if let screen = open { finished.append(screen) }
                open = Screen(keys: keys, text: text, lineCount: lines.count, first: frame.second, last: frame.second)
            }
        }
        if let open { finished.append(open) }
        // 다음 화면이 바로 이어지면 앞 조각을 거기서 끝낸다(1초 단위 프레임이라 끝을 +1초로 잡으면 겹친다).
        var clips: [SubtitleClip] = []
        for (index, screen) in finished.enumerated() {
            var end = screen.last + 1
            if index + 1 < finished.count { end = min(end, finished[index + 1].first) }
            clips.append(SubtitleClip(start: screen.first * 1000 + offsetMs, end: end * 1000 + offsetMs,
                                      kind: .screen, text: screen.text))
        }
        return clips
    }

    /// 믿을 만하고 의미 있는 글자가 2개 이상인 글줄. 같은 글줄이 두 번 잡히면 처음 것만 둔다.
    private static func usable(_ lines: [RecognizedLine], minConfidence: Float) -> [RecognizedLine] {
        var seen = Set<String>()
        return lines.compactMap { line in
            guard line.confidence >= minConfidence else { return nil }
            let key = normalize(line.text)
            guard meaningfulCount(key) >= 2, seen.insert(key).inserted else { return nil }
            var trimmed = line
            trimmed.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        }
    }

    /// 화면 읽는 순서로 줄을 묶는다: 위 → 아래, 같은 줄(세로 가운데가 글자 높이 절반 안)이면 왼쪽 → 오른쪽.
    /// 위치를 모르는 글줄은 인식한 순서대로 맨 뒤에 둔다.
    static func readingOrder(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        let placed = lines.filter { $0.box != nil }.sorted { $0.box!.midY < $1.box!.midY }
        var rows: [[RecognizedLine]] = []
        var rowMid = 0.0
        var rowHeight = 0.0
        for line in placed {
            let box = line.box!
            if let last = rows.indices.last, abs(box.midY - rowMid) <= min(box.height, rowHeight) / 2 {
                rows[last].append(line)
                let count = Double(rows[last].count)
                rowMid += (box.midY - rowMid) / count
                rowHeight = max(rowHeight, box.height)
            } else {
                rows.append([line])
                rowMid = box.midY
                rowHeight = box.height
            }
        }
        rows = rows.map { $0.sorted { $0.box!.x < $1.box!.x } }
        rows += lines.filter { $0.box == nil }.map { [$0] }
        return rows
    }

    private static func joined(_ rows: [[RecognizedLine]]) -> String {
        rows.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    /// 같은 화면이다: 글줄 묶음이 절반 이상 같다(작은 쪽 기준). 한두 줄이 잠깐 빠지거나 더해져도 이어진다.
    private static func isSameScreen(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let common = a.intersection(b).count
        return common > 0 && Double(common) * 2 >= Double(min(a.count, b.count))
    }

    private static func normalize(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !$0.properties.isWhitespace
        })
    }

    private static func meaningfulCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return false
            default:
                return true
            }
        }.count
    }
}
