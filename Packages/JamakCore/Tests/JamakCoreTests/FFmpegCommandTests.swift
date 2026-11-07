import Testing
import Foundation
@testable import JamakCore

@Suite struct FFmpegCommandTests {
    let prefix = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"]
    let inURL = URL(fileURLWithPath: "/tmp/in put.mkv")
    let outURL = URL(fileURLWithPath: "/tmp/out.mp4")

    @Test func remux() {
        #expect(FFmpegCommand.remux(input: inURL, output: outURL) == prefix + [
            "-i", "/tmp/in put.mkv", "-map", "0:V:0", "-map", "0:a?", "-c", "copy",
            "-movflags", "+faststart", "/tmp/out.mp4",
        ])
    }

    @Test func remuxWithAAC() {
        #expect(FFmpegCommand.remuxWithAACAudio(input: inURL, output: outURL) == prefix + [
            "-i", "/tmp/in put.mkv", "-map", "0:V:0", "-map", "0:a?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", "/tmp/out.mp4",
        ])
    }

    @Test func muxSubtitlesMKV() {
        let subs = [
            (url: URL(fileURLWithPath: "/tmp/a.srt"), language: "ko", title: "한국어"),
            (url: URL(fileURLWithPath: "/tmp/b.srt"), language: "ja", title: "일본어"),
        ]
        let out = URL(fileURLWithPath: "/tmp/out.mkv")
        #expect(FFmpegCommand.muxSubtitles(video: inURL, subtitles: subs, output: out, container: .mkv) == prefix + [
            "-i", "/tmp/in put.mkv", "-i", "/tmp/a.srt", "-i", "/tmp/b.srt",
            "-map", "0:V", "-map", "0:a?", "-map", "1:0", "-map", "2:0",
            "-c", "copy", "-c:s", "srt",
            "-metadata:s:s:0", "language=kor", "-metadata:s:s:0", "title=한국어",
            "-metadata:s:s:1", "language=jpn", "-metadata:s:s:1", "title=일본어",
            "/tmp/out.mkv",
        ])
    }

    @Test func muxSubtitlesMP4() {
        let subs = [(url: URL(fileURLWithPath: "/tmp/a.srt"), language: "en", title: "영어")]
        #expect(FFmpegCommand.muxSubtitles(video: inURL, subtitles: subs, output: outURL, container: .mp4) == prefix + [
            "-i", "/tmp/in put.mkv", "-i", "/tmp/a.srt",
            "-map", "0:V", "-map", "0:a?", "-map", "1:0",
            "-c", "copy", "-c:s", "mov_text",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=영어",
            "-metadata:s:s:0", "handler_name=영어",
            "-movflags", "+faststart", "/tmp/out.mp4",
        ])
    }

    @Test func muxSubtitlesMP4WithHEVCTag() {
        let subs = [(url: URL(fileURLWithPath: "/tmp/a.srt"), language: "en", title: "영어")]
        #expect(FFmpegCommand.muxSubtitles(video: inURL, subtitles: subs, output: outURL, container: .mp4,
                                           videoTag: "hvc1") == prefix + [
            "-i", "/tmp/in put.mkv", "-i", "/tmp/a.srt",
            "-map", "0:V", "-map", "0:a?", "-map", "1:0",
            "-c", "copy", "-c:s", "mov_text", "-tag:v", "hvc1",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=영어",
            "-metadata:s:s:0", "handler_name=영어",
            "-movflags", "+faststart", "/tmp/out.mp4",
        ])
        // mkv에는 태그를 쓰지 않는다.
        let mkv = FFmpegCommand.muxSubtitles(video: inURL, subtitles: subs, output: outURL, container: .mkv,
                                             videoTag: "hvc1")
        #expect(!mkv.contains("-tag:v"))
    }

    @Test func alpha3Table() {
        #expect(FFmpegCommand.alpha3("ja") == "jpn")
        #expect(FFmpegCommand.alpha3("ko") == "kor")
        #expect(FFmpegCommand.alpha3("en") == "eng")
        #expect(FFmpegCommand.alpha3("en-US") == "eng")
        #expect(FFmpegCommand.alpha3("zh-Hans") == "chi")
        #expect(FFmpegCommand.alpha3("fr") == "fre")
        #expect(FFmpegCommand.alpha3("de") == "ger")
        #expect(FFmpegCommand.alpha3("xx-unknown") == "und")
        #expect(FFmpegCommand.alpha3("") == "und")
    }

    @Test func remuxWithVideoTag() {
        #expect(FFmpegCommand.remux(input: inURL, output: outURL, videoTag: "hvc1") == prefix + [
            "-i", "/tmp/in put.mkv", "-map", "0:V:0", "-map", "0:a?", "-c", "copy",
            "-tag:v", "hvc1", "-movflags", "+faststart", "/tmp/out.mp4",
        ])
    }

    @Test func remuxWithAACAndVideoTag() {
        #expect(FFmpegCommand.remuxWithAACAudio(input: inURL, output: outURL, videoTag: "hvc1") == prefix + [
            "-i", "/tmp/in put.mkv", "-map", "0:V:0", "-map", "0:a?",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-tag:v", "hvc1", "-movflags", "+faststart", "/tmp/out.mp4",
        ])
    }

    @Test func mp4VideoTag() {
        #expect(FFmpegCommand.mp4VideoTag(forCodec: "hevc") == "hvc1")
        #expect(FFmpegCommand.mp4VideoTag(forCodec: "h264") == nil)
        #expect(FFmpegCommand.mp4VideoTag(forCodec: nil) == nil)
    }

    @Test func progressParse() {
        #expect(FFmpegProgress.parse(line: "out_time_ms=12345678") == 12345)
        #expect(FFmpegProgress.parse(line: "out_time_us=2000999\n") == 2000)
        #expect(FFmpegProgress.parse(line: "out_time_ms=0") == 0)
        #expect(FFmpegProgress.parse(line: "out_time_ms=N/A") == nil)
        #expect(FFmpegProgress.parse(line: "out_time_ms=-9000") == nil)
        #expect(FFmpegProgress.parse(line: "out_time_ms=abc") == nil)
        #expect(FFmpegProgress.parse(line: "frame=10") == nil)
        #expect(FFmpegProgress.parse(line: "progress=end") == nil)
    }
}
