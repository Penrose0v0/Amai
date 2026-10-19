import Foundation
import Testing
@testable import AmaiCore

@Suite("AmaiCore contracts")
struct ContractsTests {
    @Test("PerceptionEvent round-trips through JSON")
    func perceptionEventCodable() throws {
        let event = PerceptionEvent(
            wallTime: Date(timeIntervalSince1970: 1_760_000_000),
            monoTime: 42,
            source: .screen,
            kind: .screenFrame,
            payloadRef: "raw/2026-10-19/000001.jpg",
            metadata: PerceptionMetadata(app: "Xcode", bundleId: "com.apple.dt.Xcode", idleSeconds: 3.5)
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(PerceptionEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("TimeRange duration")
    func timeRangeDuration() {
        let start = Date(timeIntervalSince1970: 0)
        let range = TimeRange(start: start, end: start.addingTimeInterval(900))
        #expect(range.duration == 900)
    }

    @Test("ActivitySegment preserves category and confidence")
    func activitySegmentCodable() throws {
        let start = Date(timeIntervalSince1970: 0)
        let segment = ActivitySegment(
            timeRange: TimeRange(start: start, end: start.addingTimeInterval(600)),
            title: "阅读架构文档",
            summary: "在编辑器中阅读 architecture.md",
            category: .research,
            apps: ["com.microsoft.VSCode"],
            observations: [],
            confidence: 0.8,
            provider: "test"
        )
        let decoded = try JSONDecoder().decode(
            ActivitySegment.self, from: JSONEncoder().encode(segment)
        )
        #expect(decoded.category == .research)
        #expect(decoded.confidence == 0.8)
    }

    @Test("SystemClock is monotonic")
    func monotonicClock() {
        let clock = SystemClock()
        let a = clock.monotonicNanoseconds()
        let b = clock.monotonicNanoseconds()
        #expect(b >= a)
    }
}
