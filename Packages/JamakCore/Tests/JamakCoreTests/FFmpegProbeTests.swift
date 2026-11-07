import Testing
@testable import JamakCore

@Suite struct FFmpegProbeTests {
    static func stderr(duration: String, video: String) -> String {
        """
        Input #0, matroska,webm, from 'in.mkv':
          Metadata:
            ENCODER         : Lavf61.7.100
          Duration: \(duration), start: 0.000000, bitrate: 58 kb/s
          Stream #0:0: \(video)
              Metadata:
                DURATION        : 00:00:02.000000000
          Stream #0:1(eng): Audio: aac (LC), 48000 Hz, stereo, fltp (default)
          Stream #0:2(eng): Subtitle: subrip (srt)
        At least one output file must be specified
        """
    }

    @Test func parsesDurationAndHEVC() {
        let info = FFmpegProbe.parse(stderr: Self.stderr(
            duration: "01:02:03.45",
            video: "Video: hevc (Main), yuv420p(tv, progressive), 1920x1080, 23.98 fps"))
        #expect(info == FFmpegProbeInfo(durationMs: 3_723_450, videoCodec: "hevc"))
    }

    @Test func parsesH264() {
        let info = FFmpegProbe.parse(stderr: Self.stderr(
            duration: "00:00:03.00", video: "Video: h264 (High), yuv420p(progressive), 320x240, 30 fps"))
        #expect(info == FFmpegProbeInfo(durationMs: 3000, videoCodec: "h264"))
    }

    @Test func fractionDigits() {
        let video = "Video: h264, yuv420p"
        #expect(FFmpegProbe.parse(stderr: Self.stderr(duration: "00:00:01.5", video: video)).durationMs == 1500)
        #expect(FFmpegProbe.parse(stderr: Self.stderr(duration: "00:00:01.50", video: video)).durationMs == 1500)
        #expect(FFmpegProbe.parse(stderr: Self.stderr(duration: "00:00:01.123", video: video)).durationMs == 1123)
        #expect(FFmpegProbe.parse(stderr: Self.stderr(duration: "00:00:01.12345", video: video)).durationMs == 1123)
    }

    @Test func durationNotAvailable() {
        let info = FFmpegProbe.parse(stderr: Self.stderr(duration: "N/A", video: "Video: hevc, yuv420p"))
        #expect(info == FFmpegProbeInfo(durationMs: nil, videoCodec: "hevc"))
    }

    @Test func missingEverything() {
        #expect(FFmpegProbe.parse(stderr: "in.mkv: Invalid data found when processing input")
            == FFmpegProbeInfo(durationMs: nil, videoCodec: nil))
    }

    /// 표지 그림(attached pic)은 영상 스트림이 아니다.
    @Test func skipsAttachedPicture() {
        let text = """
          Duration: 00:00:10.00, start: 0.000000, bitrate: 1 kb/s
          Stream #0:0: Video: mjpeg (Baseline), yuvj420p, 600x600, 90k tbn (attached pic)
          Stream #0:1: Video: hevc (Main), yuv420p, 1280x720
        """
        #expect(FFmpegProbe.parse(stderr: text) == FFmpegProbeInfo(durationMs: 10_000, videoCodec: "hevc"))
    }

    /// mp4 표지 그림이 먼저 나와도 `-map 0:V:0`이 고르는 스트림(표지가 아닌 첫 영상)의 코덱을 고른다.
    @Test func matchesMappedVideoStreamWithBracketedIDs() {
        let text = """
          Duration: 00:00:10.00, start: 0.000000, bitrate: 1 kb/s
          Stream #0:0[0x1](und): Video: png, rgba(pc), 600x600 [SAR 1:1 DAR 1:1], 90k tbr, 90k tbn (attached pic)
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp (default)
          Stream #0:2[0x3](und): Video: hevc (Main) (hvc1 / 0x31637668), yuv420p(tv), 1920x1080, 23.98 fps (default)
        """
        #expect(FFmpegProbe.parse(stderr: text) == FFmpegProbeInfo(durationMs: 10_000, videoCodec: "hevc"))
    }
}
