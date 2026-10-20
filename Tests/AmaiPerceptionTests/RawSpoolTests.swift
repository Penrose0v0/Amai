import AmaiCore
import Foundation
import Testing
@testable import AmaiPerception

@Suite("RawSpool")
struct RawSpoolTests {
    private func event(at date: Date, clock: FakeClock) -> PerceptionEvent {
        PerceptionEvent(
            wallTime: date, monoTime: clock.monotonicNanoseconds(),
            source: .screen, kind: .screenFrame, payloadRef: nil
        )
    }

    @Test("append writes payload under the day directory and tracks bytes")
    func appendWritesPayload() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let spool = try RawSpool(root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!)

        let payload = Data(repeating: 0xAB, count: 1024)
        let stored = try await spool.append(event(at: clock.now(), clock: clock), payload: payload)

        let ref = try #require(stored.payloadRef)
        // FakeClock 默认时间 1_760_000_000 = 2025-10-09T08:53:20Z
        #expect(ref.hasPrefix("2025-10-09/"))
        #expect(ref.hasSuffix(".jpg"))
        let url = try #require(await spool.payloadURL(for: stored))
        #expect(try Data(contentsOf: url) == payload)
        #expect(await spool.totalBytes > 1024)

        let events = try await spool.events(on: clock.now())
        #expect(events.count == 1)
        #expect(events.first?.id == stored.id)
    }

    @Test("TTL purge removes whole day directories older than maxAge")
    func ttlPurge() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let limits = RawSpoolLimits(maxBytes: 100 * 1024 * 1024, maxAge: 3600)
        let spool = try RawSpool(root: root, limits: limits, clock: clock, timeZone: TimeZone(identifier: "UTC")!)

        let old = clock.now().addingTimeInterval(-3 * 86_400)
        try await spool.append(event(at: old, clock: clock), payload: Data(repeating: 1, count: 100))
        try await spool.append(event(at: clock.now(), clock: clock), payload: Data(repeating: 2, count: 100))

        try await spool.purge()

        #expect(try await spool.events(on: old).isEmpty)
        #expect(try await spool.events(on: clock.now()).count == 1)
    }

    @Test("capacity purge removes oldest payloads but keeps index lines")
    func capacityPurge() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        // 下限 64 MB 是配置校验的事；这里直接构造一个小上限来测清理逻辑。
        let limits = RawSpoolLimits(maxBytes: 2_500, maxAge: 86_400)
        let spool = try RawSpool(root: root, limits: limits, clock: clock, timeZone: TimeZone(identifier: "UTC")!)

        var stored: [PerceptionEvent] = []
        for i in 0..<4 {
            let e = try await spool.append(
                event(at: clock.now().addingTimeInterval(Double(i)), clock: clock),
                payload: Data(repeating: UInt8(i), count: 1_000)
            )
            stored.append(e)
        }

        #expect(await spool.totalBytes <= 2_500)
        // 最旧的 payload 被删，最新的保留。
        #expect(await spool.payloadURL(for: stored[0]) == nil)
        #expect(await spool.payloadURL(for: stored[3]) != nil)
        // 索引行全部保留，时间线连续。
        #expect(try await spool.events(on: clock.now()).count == 4)
    }

    @Test("reopening the spool recovers byte accounting from disk")
    func recovery() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let first = try RawSpool(root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        try await first.append(event(at: clock.now(), clock: clock), payload: Data(repeating: 7, count: 4_096))
        let expected = await first.totalBytes

        let second = try RawSpool(root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        #expect(await second.totalBytes == expected)
    }

    @Test("corrupt index lines are skipped")
    func corruptLines() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let spool = try RawSpool(root: root, limits: .default, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        try await spool.append(event(at: clock.now(), clock: clock), payload: nil)

        let index = root.appendingPathComponent("2025-10-09/events.jsonl")
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()

        #expect(try await spool.events(on: clock.now()).count == 1)
    }
}
