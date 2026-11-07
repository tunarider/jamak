import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 1초 간격 프레임을 짧은 변 720px JPEG(품질 0.7)로 저장한다.
public enum FrameSampler {
    static let shortSide: CGFloat = 720

    public enum CaptureError: Error { case cannotWrite(URL) }

    /// 123 → "000123.jpg"
    public static func fileName(second: Int) -> String {
        String(format: "%06d.jpg", second)
    }

    /// 짧은 변이 720을 넘을 때만 줄인다. 넘지 않으면 `.zero`(원본 크기).
    static func maximumSize(for natural: CGSize) -> CGSize {
        let w = abs(natural.width), h = abs(natural.height)
        let short = min(w, h)
        guard short > shortSide else { return .zero }
        let scale = shortSide / short
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    /// seconds의 각 초에 대해 `frames/<초 6자리>.jpg`를 저장한다. 이미 있으면 건너뛴다.
    /// 저장한 초를 `onSaved`에 알린다. 디코딩에 실패한 초는 ±0.5초 허용으로 한 번 더 시도하고,
    /// 그래도 안 되면 건너뛰어 실패한 초(오름차순)로 돌려준다. 취소는 던진다.
    @discardableResult
    public static func capture(video: URL, seconds: [Int], into folder: URL,
                               onSaved: @Sendable (Int) -> Void) async throws -> [Int] {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var seen = Set<Int>()
        let pending = seconds.filter { second in
            seen.insert(second).inserted
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName(second: second)).path)
        }
        guard !pending.isEmpty else { return [] }

        let asset = AVURLAsset(url: video)
        var size = CGSize.zero
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            size = maximumSize(for: natural.applying(transform))
        }
        func makeGenerator(tolerance seconds: Double) -> AVAssetImageGenerator {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            let tolerance = CMTime(seconds: seconds, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            return generator
        }
        func time(_ second: Int) -> CMTime { CMTime(seconds: Double(second), preferredTimescale: 600) }

        var retry: [Int] = []
        for await result in makeGenerator(tolerance: 0.1).images(for: pending.map(time)) {
            try Task.checkCancellation()
            let second = Int(result.requestedTime.seconds.rounded())
            if let image = try? result.image {
                try writeJPEG(image, to: folder.appendingPathComponent(fileName(second: second)))
                onSaved(second)
            } else {
                retry.append(second)
            }
        }
        try Task.checkCancellation()

        var failed: [Int] = []
        let wide = makeGenerator(tolerance: 0.5)
        for second in retry.sorted() {
            try Task.checkCancellation()
            if let image = try? await wide.image(at: time(second)).image {
                try writeJPEG(image, to: folder.appendingPathComponent(fileName(second: second)))
                onSaved(second)
            } else {
                failed.append(second)
            }
        }
        try Task.checkCancellation()
        return failed
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CaptureError.cannotWrite(url) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw CaptureError.cannotWrite(url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
