import AVFoundation
import Foundation
import JamakCore
import SoundAnalysis

/// SoundAnalysis 내장 분류기(version1)로 1초 창(겹침 0.5)마다 최상위 라벨을 낸다.
public enum SoundClassifier {
    public static func classify(wav: URL, onProgress: @Sendable (Double) -> Void) async throws -> [SoundWindow] {
        try Task.checkCancellation()
        let analyzer = try SNAudioFileAnalyzer(url: wav)
        let file = try AVAudioFile(forReading: wav)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
        request.overlapFactor = 0.5

        return try await withoutActuallyEscaping(onProgress) { escapable in
            let collector = Collector(duration: duration, onProgress: escapable)
            try analyzer.add(request, withObserver: collector)

            let box = AnalyzerBox(analyzer)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        box.analyzer.analyze()
                        continuation.resume()
                    }
                }
            } onCancel: {
                box.analyzer.cancelAnalysis()
            }
            try Task.checkCancellation()
            if let error = collector.failure { throw error }
            escapable(1)
            return collector.windows
        }
    }

    /// 분류기가 알고 있는 모든 라벨 식별자(정렬).
    public static func knownLabels() throws -> [String] {
        try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications.sorted()
    }

    /// `SNAudioFileAnalyzer`는 Sendable이 아니다. `analyze()`(작업 큐)와 `cancelAnalysis()`(취소)만 서로 다른 스레드에서 부른다.
    private final class AnalyzerBox: @unchecked Sendable {
        let analyzer: SNAudioFileAnalyzer
        init(_ analyzer: SNAudioFileAnalyzer) { self.analyzer = analyzer }
    }

    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SoundWindow] = []
        private var error: Error?
        private let duration: Double
        private let onProgress: @Sendable (Double) -> Void

        init(duration: Double, onProgress: @escaping @Sendable (Double) -> Void) {
            self.duration = duration
            self.onProgress = onProgress
        }

        var windows: [SoundWindow] { lock.lock(); defer { lock.unlock() }; return items }
        var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds, length = result.timeRange.duration.seconds
            if let top = result.classifications.first {
                lock.lock()
                items.append(SoundWindow(startMs: Int((start * 1000).rounded()),
                                         endMs: Int(((start + length) * 1000).rounded()),
                                         label: top.identifier, confidence: top.confidence))
                lock.unlock()
            }
            if duration > 0 { onProgress(min(1, (start + length) / duration)) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.lock(); self.error = error; lock.unlock()
        }
    }
}
