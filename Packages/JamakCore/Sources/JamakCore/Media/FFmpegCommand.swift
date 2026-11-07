import Foundation

public enum SubtitleContainer: Sendable { case mkv, mp4 }

/// ffmpeg 인자 배열을 만든다. 셸 문자열이 아니므로 경로는 따옴표 없이 그대로 넣는다.
public enum FFmpegCommand {
    private static let common = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]

    /// `videoTag`: mp4에 쓸 영상 코덱 태그(`mp4VideoTag(forCodec:)`). nil이면 ffmpeg 기본값.
    /// 영상은 `0:V:0`(표지 그림을 뺀 첫 영상)이다. `FFmpegProbe`도 같은 스트림의 코덱을 고른다.
    public static func remux(input: URL, output: URL, videoTag: String? = nil) -> [String] {
        common + ["-i", input.path, "-map", "0:V:0", "-map", "0:a?", "-c", "copy"]
            + tag(videoTag) + ["-movflags", "+faststart", output.path]
    }

    public static func remuxWithAACAudio(input: URL, output: URL, videoTag: String? = nil) -> [String] {
        common + ["-i", input.path, "-map", "0:V:0", "-map", "0:a?",
                  "-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]
            + tag(videoTag) + ["-movflags", "+faststart", output.path]
    }

    /// 복사한 영상을 AVFoundation이 재생하려면 필요한 mp4 태그. HEVC는 ffmpeg 기본(hev1)이면 재생되지 않아 hvc1을 쓴다.
    /// 그 밖의 코덱은 nil(기본값 그대로).
    public static func mp4VideoTag(forCodec codec: String?) -> String? {
        codec == "hevc" ? "hvc1" : nil
    }

    private static func tag(_ videoTag: String?) -> [String] {
        videoTag.map { ["-tag:v", $0] } ?? []
    }

    public static func muxSubtitles(
        video: URL,
        subtitles: [(url: URL, language: String, title: String)],
        output: URL,
        container: SubtitleContainer,
        videoTag: String? = nil
    ) -> [String] {
        var args = common + ["-i", video.path]
        for sub in subtitles { args += ["-i", sub.url.path] }
        // 대문자 V: 표지 그림(attached pic) 같은 그림 스트림은 빼고 실제 영상만 넣는다.
        args += ["-map", "0:V", "-map", "0:a?"]
        for index in subtitles.indices { args += ["-map", "\(index + 1):0"] }
        args += ["-c", "copy", "-c:s", container == .mkv ? "srt" : "mov_text"]
        // mp4의 영상 코덱 태그(HEVC는 hvc1이어야 QuickTime이 재생한다). mkv에는 쓰지 않는다.
        if container == .mp4 { args += tag(videoTag) }
        for (index, sub) in subtitles.enumerated() {
            let stream = "-metadata:s:s:\(index)"
            args += [stream, "language=\(alpha3(sub.language))", stream, "title=\(sub.title)"]
            // mp4(mov)는 트랙 이름을 title이 아니라 handler_name으로 쓴다.
            if container == .mp4 { args += [stream, "handler_name=\(sub.title)"] }
        }
        if container == .mp4 { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        return args
    }

    /// 언어 식별자를 ISO 639-2 세 글자 코드로 바꾼다. T형과 B형이 다른 언어는 B형을 쓴다. 모르면 "und".
    public static func alpha3(_ language: String) -> String {
        let code = Locale.Language(identifier: language).languageCode
        guard let base = code?.identifier, !base.isEmpty else { return "und" }
        if let b = bibliographic[base] { return b }
        let three = code?.identifier(.alpha3) ?? ""
        return three.isEmpty ? "und" : three
    }

    private static let bibliographic: [String: String] = [
        "zh": "chi", "fr": "fre", "de": "ger", "cs": "cze", "nl": "dut", "el": "gre",
        "fa": "per", "ro": "rum", "sk": "slo", "hy": "arm", "ka": "geo", "is": "ice",
        "mk": "mac", "ms": "may", "my": "bur", "sq": "alb", "eu": "baq", "bo": "tib",
        "cy": "wel", "mi": "mao",
    ]
}

public struct FFmpegProgress: Sendable {
    /// `out_time_ms=`/`out_time_us=` 줄(ffmpeg에서는 둘 다 마이크로초)을 ms로 바꾼다. 그 외 줄이나 N/A, 음수는 nil.
    public static func parse(line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in ["out_time_ms=", "out_time_us="] where trimmed.hasPrefix(key) {
            guard let micros = Int(trimmed.dropFirst(key.count)), micros >= 0 else { return nil }
            return micros / 1000
        }
        return nil
    }
}
