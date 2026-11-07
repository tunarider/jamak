import Testing
import Foundation
@testable import JamakCore

struct SRTExporterTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SRTExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func fileNameDropsVideoExtension() {
        #expect(SRTExporter.fileName(videoName: "港の夏.mkv", language: .ko) == "港の夏.ko.srt")
        #expect(SRTExporter.fileName(videoName: "a.b.mkv", language: .ko) == "a.b.ko.srt")
        #expect(SRTExporter.fileName(videoName: "noext", language: .ko) == "noext.ko.srt")
    }

    @Test func fileNameUsesLanguageCode() {
        #expect(SRTExporter.fileName(videoName: "港の夏.mkv", language: .ja) == "港の夏.ja.srt")
    }

    @Test func conflictsListsExistingFiles() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("v.en.srt"))
        try Data().write(to: folder.appendingPathComponent("v.ko.srt"))
        let found = SRTExporter.conflicts(languages: [.ko, .ja, .en], videoName: "v.mp4", in: folder)
        #expect(found.map(\.lastPathComponent) == ["v.ko.srt", "v.en.srt"])
    }

    @Test func exportWritesEachLanguageWithFallback() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = Cue(start: 800, end: 3200, kind: .speech, texts: [.ko: "좋은 아침입니다", .ja: "おはよう"])
        let b = Cue(start: 4000, end: 5000, kind: .sound, texts: [.ko: "포성"])
        let set = CueSet(name: "기본", languages: [.ko, .ja], cues: [b, a])
        try Data("old".utf8).write(to: folder.appendingPathComponent("v.ko.srt"))
        let urls = try SRTExporter.export(set, languages: [.ko, .ja], original: .ko, fallback: true, videoName: "v.mp4", to: folder)
        #expect(urls.map(\.lastPathComponent) == ["v.ko.srt", "v.ja.srt"])
        let ko = SRTCodec.parse(try Data(contentsOf: urls[0]))
        #expect(ko.map(\.text) == ["좋은 아침입니다", "포성"])
        #expect(ko.map(\.kind) == [.speech, .sound])
        #expect(ko.map { [$0.start, $0.end] } == [[800, 3200], [4000, 5000]])
        let ja = SRTCodec.parse(try Data(contentsOf: urls[1]))
        #expect(ja.map(\.text) == ["おはよう", "포성"])
        let noFallback = try SRTExporter.export(set, languages: [.ja], original: .ko, fallback: false, videoName: "w.mp4", to: folder)
        #expect(SRTCodec.parse(try Data(contentsOf: noFallback[0])).map(\.text) == ["おはよう"])
    }

    @Test func exportPropagatesWriteErrors() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let set = CueSet.initial(language: .ko)
        #expect(throws: (any Error).self) {
            _ = try SRTExporter.export(set, languages: [.ko], original: .ko, fallback: true, videoName: "v.mp4", to: missing)
        }
    }
}
