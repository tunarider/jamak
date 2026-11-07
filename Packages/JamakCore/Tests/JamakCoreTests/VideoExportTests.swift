import Testing
import Foundation
@testable import JamakCore

struct VideoExportTests {
    @Test func defaultFileNameUsesContainerExtension() {
        #expect(VideoExport.defaultFileName(videoName: "港の夏.mp4", container: .mkv) == "港の夏.subs.mkv")
        #expect(VideoExport.defaultFileName(videoName: "a.b.mkv", container: .mp4) == "a.b.subs.mp4")
        #expect(VideoExport.defaultFileName(videoName: "noext", container: .mkv) == "noext.subs.mkv")
    }

    @Test func partialURLLivesInGivenFolderKeepingExtensionLast() {
        let folder = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        let output = URL(fileURLWithPath: "/elsewhere/dir/a.subs.mkv")
        #expect(VideoExport.partialURL(for: output, in: folder).path == "/tmp/work/a.subs.partial.mkv")
        #expect(VideoExport.partialURL(for: URL(fileURLWithPath: "/x/y.mp4"), in: folder).path == "/tmp/work/y.partial.mp4")
    }

    @Test func fileExtensionPerContainer() {
        #expect(VideoExport.fileExtension(.mkv) == "mkv")
        #expect(VideoExport.fileExtension(.mp4) == "mp4")
    }
}
