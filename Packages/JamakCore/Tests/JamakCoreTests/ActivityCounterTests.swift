import Testing
@testable import JamakCore

struct ActivityCounterTests {
    @Test func activityAggregatesConcurrentRequests() {
        var c = ActivityCounter()
        #expect(c.active == 0 && c.receivingCount == 0)
        let a = c.begin()
        let b = c.begin()
        #expect(a != b)
        #expect(c.active == 2 && c.receivingCount == 0)
        c.receiving(a)
        c.receiving(a)   // 요청마다 한 번만 센다(재시도로 여러 번 와도)
        #expect(c.active == 2 && c.receivingCount == 1)
        c.end(b)
        #expect(c.active == 1 && c.receivingCount == 1)
        c.end(a)
        #expect(c.active == 0 && c.receivingCount == 0)
    }

    @Test func lateReceivingAfterEndIgnored() {
        var c = ActivityCounter()
        let a = c.begin()
        let b = c.begin()
        c.end(a)
        c.receiving(a)   // 끝난 뒤 늦게 도착
        #expect(c.active == 1 && c.receivingCount == 0)
        c.end(b)
        c.receiving(b)
        #expect(c.active == 0 && c.receivingCount == 0)
    }

    @Test func endIsIdempotent() {
        var c = ActivityCounter()
        let a = c.begin()
        let b = c.begin()
        c.receiving(a)
        c.end(a)
        c.end(a)
        #expect(c.active == 1 && c.receivingCount == 0)
        c.end(b)
        c.end(b)
        #expect(c.active == 0 && c.receivingCount == 0)
    }
}
