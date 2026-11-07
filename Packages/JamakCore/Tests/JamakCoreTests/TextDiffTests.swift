import Testing
import Foundation
@testable import JamakCore

struct TextDiffTests {
    @Test func diffSimpleReplace() {
        #expect(TextDiff.parts(from: "ファイア！", to: "撃て！")
                == [.removed("ファイア"), .added("撃て"), .same("！")])
    }

    @Test func diffIdentical() {
        #expect(TextDiff.parts(from: "abc", to: "abc") == [.same("abc")])
        #expect(TextDiff.parts(from: "", to: "").isEmpty)
    }

    @Test func diffEmptyOld() {
        #expect(TextDiff.parts(from: "", to: "abc") == [.added("abc")])
        #expect(TextDiff.parts(from: "abc", to: "") == [.removed("abc")])
    }

    @Test func diffInsertionInMiddle() {
        #expect(TextDiff.parts(from: "ac", to: "abc") == [.same("a"), .added("b"), .same("c")])
    }

    @Test func diffLongFallsBack() {
        let old = String(repeating: "a", count: 401), new = "b"
        #expect(TextDiff.parts(from: old, to: new) == [.removed(old), .added(new)])
    }
}
