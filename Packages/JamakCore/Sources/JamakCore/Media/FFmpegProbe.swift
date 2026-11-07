import Foundation

public struct FFmpegProbeInfo: Equatable, Sendable {
    /// 입력의 길이. `Duration: N/A`거나 없으면 nil.
    public var durationMs: Int?
    /// 첫 영상 스트림의 코덱 이름(예: "hevc", "h264"). 표지 그림(attached pic)은 건너뛴다.
    /// `FFmpegCommand`의 `-map 0:V:0`이 고르는 스트림과 같다.
    public var videoCodec: String?

    public init(durationMs: Int?, videoCodec: String?) {
        self.durationMs = durationMs
        self.videoCodec = videoCodec
    }
}

/// `ffmpeg -i <입력>`이 stderr에 쓰는 입력 정보를 읽는다.
public enum FFmpegProbe {
    public static func parse(stderr: String) -> FFmpegProbeInfo {
        var info = FFmpegProbeInfo(durationMs: nil, videoCodec: nil)
        var sawDuration = false
        for raw in stderr.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !sawDuration, line.hasPrefix("Duration:") {
                sawDuration = true
                info.durationMs = duration(line)
            } else if info.videoCodec == nil, line.hasPrefix("Stream #"),
                      !line.contains("(attached pic)"),
                      let range = line.range(of: ": Video: ") {
                let rest = line[range.upperBound...]
                let name = rest.prefix { $0 != " " && $0 != "," && $0 != "(" }
                if !name.isEmpty { info.videoCodec = String(name) }
            }
        }
        return info
    }

    /// `Duration: 01:02:03.45, start: …` → ms. 소수부는 앞의 세 자리까지 쓴다.
    private static func duration(_ line: String) -> Int? {
        guard let match = line.firstMatch(of: /^Duration: (\d+):(\d+):(\d+)(?:\.(\d+))?/),
              let h = Int(match.1), let m = Int(match.2), let s = Int(match.3) else { return nil }
        let digits = String((match.4 ?? "").prefix(3))
        let fraction = Int(digits.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return ((h * 60 + m) * 60 + s) * 1000 + fraction
    }
}
