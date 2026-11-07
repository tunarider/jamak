import Foundation
import JamakCore
import Vision

/// Vision으로 프레임 JPEG의 글자를 읽는다.
public enum TextRecognizer {
    /// 한 장을 읽는다. 관찰마다 최상위 후보 하나와 화면 위치(왼쪽 위 원점 비율)를 낸다. 언어 교정은 끈다.
    public static func recognize(jpeg: URL, languages: [String]) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
        let usable = languages.filter { supported.contains($0) }
        if !usable.isEmpty { request.recognitionLanguages = usable }
        try VNImageRequestHandler(url: jpeg, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                // Vision의 상자는 왼쪽 아래가 원점이다. 화면 읽는 순서를 쓰기 쉽게 왼쪽 위 원점으로 바꾼다.
                let r = observation.boundingBox
                let box = TextBox(x: Double(r.minX), y: Double(1 - r.maxY), width: Double(r.width), height: Double(r.height))
                return RecognizedLine(text: $0.string, confidence: $0.confidence, box: box)
            }
        }
    }

    /// 여러 장을 `concurrency`개씩 읽어 초 순서로 돌려준다. 진행률은 끝난 장 수 / 전체.
    /// 읽지 못한 장은 빈 `FrameText`가 된다. 취소는 던진다.
    public static func recognize(frames: [(second: Int, url: URL)], languages: [String], concurrency: Int = 4,
                                 onProgress: @Sendable (Double) -> Void) async throws -> [FrameText] {
        try Task.checkCancellation()
        guard !frames.isEmpty else { onProgress(1); return [] }
        let limit = max(1, concurrency)
        var results: [FrameText] = []
        var done = 0
        try await withThrowingTaskGroup(of: FrameText.self) { group in
            var next = 0
            func addNext() {
                let frame = frames[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    // 한 장을 읽지 못해도(깨진 파일 등) 전체를 멈추지 않는다. 빈 프레임으로 둔다.
                    let lines = (try? recognize(jpeg: frame.url, languages: languages)) ?? []
                    try Task.checkCancellation()
                    return FrameText(second: frame.second, lines: lines)
                }
            }
            while next < min(limit, frames.count) { addNext() }
            while let item = try await group.next() {
                results.append(item)
                done += 1
                onProgress(Double(done) / Double(frames.count))
                try Task.checkCancellation()
                if next < frames.count { addNext() }
            }
        }
        return results.sorted { $0.second < $1.second }
    }

    /// 원문 언어(기본 코드 또는 BCP-47)에 맞는 Vision 인식 언어. 영어를 함께 읽고, 지원되지 않는 언어는 뺀다.
    public static func visionLanguages(for sourceLanguage: String) -> [String] {
        let base = sourceLanguage.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            .map { String($0).lowercased() } ?? ""
        let regional: [String: String] = [
            "ja": "ja-JP", "ko": "ko-KR", "en": "en-US", "zh": "zh-Hans", "fr": "fr-FR",
            "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR",
        ]
        var wanted = [regional[base] ?? base, "en-US"]
        wanted = wanted.reduce(into: []) { if !$0.contains($1) && !$1.isEmpty { $0.append($1) } }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let supported = try? request.supportedRecognitionLanguages() else { return wanted }
        let usable = wanted.filter { supported.contains($0) }
        return usable.isEmpty ? ["en-US"] : usable
    }
}
