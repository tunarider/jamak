import AVFoundation
import Foundation

/// 영상에서 16kHz 모노 16비트 wav(오디오 캐시)를 만들고 구간을 읽는다.
public enum AudioExtractor {
    static let sampleRate = 16_000.0
    /// 한 번에 쓰는 무음 길이(프레임). 2시간 분량을 메모리에 올리지 않으려고 쪼갠다.
    private static let silenceChunkFrames = 16_000 * 30

    public enum ExtractError: Error { case cannotRead(String), cannotCreateBuffer }

    private static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// 영상의 첫 음성 트랙 → 16kHz 모노 16비트 wav. 음성 트랙이 없으면 길이만큼 무음 wav.
    /// 임시 파일에 쓰고 성공하면 이름을 바꾼다. 진행률은 (쓴 프레임 / 예상 프레임)이다.
    public static func extract(video: URL, to wav: URL, durationMs: Int,
                               onProgress: @Sendable (Double) -> Void) async throws {
        let tmp = wav.deletingLastPathComponent()
            .appendingPathComponent("\(wav.deletingPathExtension().lastPathComponent).tmp.\(wav.pathExtension)")
        try? FileManager.default.removeItem(at: tmp)
        let expected = max(1, durationMs * 16)
        do {
            let asset = AVURLAsset(url: video)
            let track = try await asset.loadTracks(withMediaType: .audio).first
            let file = try AVAudioFile(forWriting: tmp, settings: wavSettings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            var written = 0
            if let track {
                // 샘플 번호 ↔ 영상 시간이 맞도록 트랙 시작 전은 무음으로 채운다.
                let start = try await track.load(.timeRange).start.seconds
                if start.isFinite, start > 0 {
                    let lead = Int((start * sampleRate).rounded())
                    try writeSilence(frames: lead, into: file, written: &written, expected: expected, onProgress: onProgress)
                }
                try await copyAudio(asset: asset, track: track, into: file, written: &written,
                                    expected: expected, onProgress: onProgress)
            }
            // 음성이 없거나 영상보다 짧으면 길이까지 무음으로 채운다.
            if written < expected {
                try writeSilence(frames: expected - written, into: file, written: &written,
                                 expected: expected, onProgress: onProgress)
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // file은 do 블록이 끝날 때 해제되어 헤더가 확정된 뒤다.
        if FileManager.default.fileExists(atPath: wav.path) {
            _ = try FileManager.default.replaceItemAt(wav, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: wav)
        }
        onProgress(1.0)
    }

    private static func copyAudio(asset: AVURLAsset, track: AVAssetTrack, into file: AVAudioFile,
                                  written: inout Int, expected: Int, onProgress: @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractError.cannotRead("출력을 추가할 수 없어요") }
        reader.add(output)
        guard reader.startReading() else {
            throw ExtractError.cannotRead(reader.error?.localizedDescription ?? "읽기를 시작하지 못했어요")
        }
        let format = file.processingFormat
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let dst = buffer.int16ChannelData?[0]
            else { throw ExtractError.cannotCreateBuffer }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 2, destination: dst)
            guard status == kCMBlockBufferNoErr else { throw ExtractError.cannotRead("복사 실패(\(status))") }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            written += frames
            onProgress(min(Double(written) / Double(expected), 0.999))
        }
        if reader.status == .failed {
            throw ExtractError.cannotRead(reader.error?.localizedDescription ?? "읽기 실패")
        }
    }

    private static func writeSilence(frames: Int, into file: AVAudioFile, written: inout Int, expected: Int,
                                     onProgress: @Sendable (Double) -> Void) throws {
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(min(frames, silenceChunkFrames)))
        else { throw ExtractError.cannotCreateBuffer }
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            let n = min(remaining, silenceChunkFrames)
            buffer.frameLength = AVAudioFrameCount(n)
            if let data = buffer.int16ChannelData?[0] { data.update(repeating: 0, count: n) }
            try file.write(from: buffer)
            remaining -= n
            written += n
            onProgress(min(Double(written) / Double(expected), 0.999))
        }
    }

    /// `samples`가 한 번에 읽는 프레임 수(1분).
    private static let readBlockFrames = 16_000 * 60

    /// wav의 [startMs, endMs) 구간을 Float 샘플(-1...1)로. 파일 길이를 넘으면 잘라 돌려준다.
    /// 결과 배열을 미리 잡아 두고 작은 버퍼로 나눠 읽어, 구간 전체 크기의 중간 버퍼를 만들지 않는다.
    public static func samples(wav: URL, startMs: Int, endMs: Int) throws -> [Float] {
        guard endMs > startMs else { return [] }
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let start = max(0, Int(Double(startMs) * rate / 1000))
        let end = min(Int(file.length), Int(Double(endMs) * rate / 1000))
        guard end > start else { return [] }
        file.framePosition = AVAudioFramePosition(start)
        let count = end - start
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(min(count, readBlockFrames)))
        else { throw ExtractError.cannotCreateBuffer }
        var result = [Float]()
        result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            let want = min(count - result.count, readBlockFrames)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(want))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData?[0] else { break }
            result.append(contentsOf: UnsafeBufferPointer(start: data, count: got))
        }
        return result
    }
}
