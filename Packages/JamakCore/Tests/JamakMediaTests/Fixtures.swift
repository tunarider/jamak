import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 미디어 테스트의 ffmpeg 위치와 픽스처 생성.
/// - 실행기로 시험할 ffmpeg(최소 빌드): `JAMAK_FFMPEG`, 없으면 `App/Vendor/bin/ffmpeg`.
/// - 픽스처를 만드는 ffmpeg(인코더가 있는 빌드): `JAMAK_FIXTURE_FFMPEG`, 없으면 `/opt/homebrew/bin/ffmpeg`.
/// 둘 중 하나라도 없으면 그 테스트는 건너뛴다.
enum Fixtures {
    /// 저장소 루트. 이 파일은 `Packages/JamakCore/Tests/JamakMediaTests/` 안에 있다.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let runnerFFmpeg: URL? = executable(
        env: "JAMAK_FFMPEG", fallback: repoRoot.appendingPathComponent("App/Vendor/bin/ffmpeg").path)

    static let fixtureFFmpeg: URL? = executable(
        env: "JAMAK_FIXTURE_FFMPEG", fallback: "/opt/homebrew/bin/ffmpeg")

    static var canRunMediaTests: Bool { runnerFFmpeg != nil && fixtureFFmpeg != nil }

    private static func executable(env: String, fallback: String) -> URL? {
        let path = ProcessInfo.processInfo.environment[env].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// 테스트마다 따로 쓰는 임시 폴더.
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamakMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum AudioCodec: String { case aac, ac3 }
    enum VideoCodec: String { case h264 = "libx264", hevc = "libx265" }

    /// `testsrc` 영상과 `sine` 음성으로 mkv를 만든다. `subtitleTracks`만큼 제목이 긴 srt 트랙을 붙인다
    /// (`ffmpeg -i`의 stderr를 4KB보다 길게 만들 때 쓴다).
    static func makeMKV(in dir: URL, name: String = "fixture.mkv", seconds: Int = 3,
                        video: VideoCodec = .h264, audio: AudioCodec = .aac,
                        subtitleTracks: Int = 0) throws -> URL {
        guard let ffmpeg = fixtureFFmpeg else { throw FixtureError.noFixtureFFmpeg }
        let out = dir.appendingPathComponent(name)
        var args = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=48000",
        ]
        if subtitleTracks > 0 {
            let srt = dir.appendingPathComponent("fixture-subtitle.srt")
            // -shortest가 자막 끝에서 자르지 않게 자막을 영상 길이만큼 보이게 한다.
            let end = String(format: "%02d:%02d:%02d,000", seconds / 3600, seconds / 60 % 60, seconds % 60)
            try Data("1\n00:00:00,000 --> \(end)\nhello\n".utf8).write(to: srt)
            args += ["-i", srt.path]
        }
        args += ["-map", "0:v", "-map", "1:a"]
        for index in 0..<subtitleTracks {
            args += ["-map", "2:0", "-metadata:s:s:\(index)",
                     "title=Subtitle track \(index + 1) with a fairly long descriptive title for signs and songs"]
        }
        args += ["-c:v", video.rawValue, "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        if video == .hevc { args += ["-x265-params", "log-level=error"] }
        args += ["-c:a", audio.rawValue, "-b:a", "128k"]
        if subtitleTracks > 0 { args += ["-c:s", "srt"] }
        args += ["-shortest", out.path]
        try run(ffmpeg, args)
        return out
    }

    /// h264(+aac) mp4. `overlayText`가 있으면 CoreText로 그린 PNG를 얹는다(Homebrew ffmpeg에는 drawtext가 없다).
    static func makeVideo(in dir: URL, name: String = "video-fixture.mp4", seconds: Int = 3,
                          withAudio: Bool = true, audioDelay: Double = 0, overlayText: String? = nil, fontName: String = "Helvetica-Bold",
                          size: (width: Int, height: Int) = (320, 240)) throws -> URL {
        guard let ffmpeg = fixtureFFmpeg else { throw FixtureError.noFixtureFFmpeg }
        let out = dir.appendingPathComponent(name)
        var args = [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=\(size.width)x\(size.height):rate=30",
        ]
        if withAudio {
            if audioDelay > 0 { args += ["-itsoffset", "\(audioDelay)"] }
            args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(Double(seconds) - audioDelay):sample_rate=48000"]
        }
        if let overlayText {
            let png = dir.appendingPathComponent("overlay-\(UUID().uuidString).png")
            try renderText(overlayText, fontName: fontName, to: png, width: size.width)
            args += ["-i", png.path, "-filter_complex", "[0:v][\(withAudio ? 2 : 1):v]overlay=0:20[v]", "-map", "[v]"]
            if withAudio { args += ["-map", "1:a"] }
        }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        if withAudio { args += ["-c:a", "aac", "-b:a", "128k", "-shortest"] }
        args.append(out.path)
        try run(ffmpeg, args)
        return out
    }

    /// 440Hz 사인파 16kHz 모노 wav.
    static func makeSineWav(in dir: URL, name: String = "sine.wav", seconds: Int = 3) throws -> URL {
        guard let ffmpeg = fixtureFFmpeg else { throw FixtureError.noFixtureFFmpeg }
        let out = dir.appendingPathComponent(name)
        try run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=16000",
                         "-ac", "1", "-c:a", "pcm_s16le", out.path])
        return out
    }

    /// 검은 바탕에 흰 글자를 가로 `width`px 띠로 그려 PNG로 저장한다(OCR이 읽기 쉽게 크고 또렷하게).
    static func renderText(_ text: String, fontName: String, to url: URL, width: Int, height: Int = 90) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.failed(-1, "bitmap context")
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(fontName as CFString, 56, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
        ctx.textPosition = CGPoint(x: 20, y: 24)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.failed(-1, "png")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError.failed(-1, "png finalize") }
    }

    static var canMakeFixtures: Bool { fixtureFFmpeg != nil }

    enum FixtureError: Error { case noFixtureFFmpeg, failed(Int32, String) }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.failed(process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}
