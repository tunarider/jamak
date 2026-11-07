import Testing
@testable import JamakCore

struct TimecodeTests {
    @Test func formats() {
        #expect(Timecode.full(3_723_045) == "01:02:03.045")
        #expect(Timecode.full(-5) == "00:00:00.000")
        #expect(Timecode.short(65_000) == "1:05")
        #expect(Timecode.short(3_725_000) == "1:02:05")
    }

    @Test func formatsTenths() {
        #expect(Timecode.tenths(860_000) == "00:14:20.0")
        #expect(Timecode.tenths(871_590) == "00:14:31.5")
        #expect(Timecode.tenths(3_723_099) == "01:02:03.0")
        #expect(Timecode.tenths(-5) == "00:00:00.0")
    }

    @Test(arguments: [
        ("01:02:03.045", 3_723_045),
        ("1:02:03,5", 3_723_500),
        ("02:03.04", 123_040),
        ("3", 3000),
        ("3.1", 3100),
        ("100:00:00.000", 360_000_000),
        (" 00:00:01.000 ", 1000),
    ])
    func parsesValid(text: String, ms: Int) {
        #expect(Timecode.parse(text) == ms)
    }

    @Test(arguments: [
        "", "00:60:00.000", "00:00:60.000", "61:00", "75", "00:00:01.0000", "00:00:01.",
        "1:2:3:4", "-1", "+1", "9999999999999:00:00", "100000:00:00", "00:-1:00", "a", "00::01", "00:00:01.-5", ".5",
    ])
    func rejectsInvalid(text: String) {
        #expect(Timecode.parse(text) == nil)
    }

    @Test func acceptsMaxHours() {
        #expect(Timecode.parse("99999:59:59.999") == 99_999 * 3_600_000 + 3_599_999)
    }

    @Test func formatParseRoundTrip() {
        for ms in [0, 1, 999, 59_999, 3_599_999, 36_000_000 + 1] {
            #expect(Timecode.parse(Timecode.full(ms)) == ms)
        }
    }
}
