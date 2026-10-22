import AmaiCore
import Foundation
import Testing
@testable import AmaiPerception

@Suite("FrameStore")
struct FrameStoreTests {
    final class ByteSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var reported: [Int64] = []
        func add(_ b: Int64) { lock.withLock { reported.append(b) } }
    }

    @Test("frames round-trip through an HEVC segment")
    func roundTrip() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        let sink = ByteSink()
        let store = FrameStore(
            root: root, clock: clock, timeZone: TimeZone(identifier: "UTC")!
        ) { bytes in sink.add(bytes) }

        let images = (0..<3).map { SyntheticImage.make(seed: $0, size: 256) }
        var refs: [FrameStore.FrameRef] = []
        for (i, image) in images.enumerated() {
            refs.append(try await store.append(image, at: clock.now().addingTimeInterval(Double(i * 10))))
        }
        #expect(refs.map(\.frameIndex) == [0, 1, 2])
        #expect(Set(refs.map(\.segment)).count == 1)
        #expect(refs[0].segment.hasPrefix("2025-10-09/"))
        #expect(refs[0].segment.hasSuffix(".mp4"))

        await store.finishSegment()
        let url = root.appendingPathComponent(refs[0].segment)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(sink.reported.count == 1 && sink.reported[0] > 0)

        // 第 1 帧读回后：尺寸一致；逐通道均值接近原图（通道顺序写反会让 R/B 偏差很大）；
        // 感知哈希上比第 0 帧和第 2 帧都更像第 1 帧。合成图是硬边色块，有损编码后哈希会有一定位差。
        let decoded = try await FrameStore.image(segmentURL: url, frameIndex: 1)
        #expect(decoded.width == 256 && decoded.height == 256)
        let diff = PixelStats.meanChannelDifference(images[1], decoded)
        #expect(diff.r < 24 && diff.g < 24 && diff.b < 24, "channel diff \(diff)")
        let same = ImageHashing.distance(ImageHashing.dHash(images[1]), ImageHashing.dHash(decoded))
        let other0 = ImageHashing.distance(ImageHashing.dHash(images[0]), ImageHashing.dHash(decoded))
        let other2 = ImageHashing.distance(ImageHashing.dHash(images[2]), ImageHashing.dHash(decoded))
        #expect(same < other0 && same < other2)
    }

    @Test("segment rotates on frame limit and on size change")
    func rotation() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FakeClock()
        var config = FrameStore.Configuration.default
        config.maxFrames = 2
        let store = FrameStore(root: root, configuration: config, clock: clock, timeZone: TimeZone(identifier: "UTC")!)

        let a = try await store.append(SyntheticImage.make(seed: 0, size: 128), at: clock.now())
        let b = try await store.append(SyntheticImage.make(seed: 1, size: 128), at: clock.now().addingTimeInterval(1))
        let c = try await store.append(SyntheticImage.make(seed: 2, size: 128), at: clock.now().addingTimeInterval(2))
        #expect(a.segment == b.segment)
        #expect(c.segment != b.segment)
        #expect(c.frameIndex == 0)

        let d = try await store.append(SyntheticImage.make(seed: 3, size: 64), at: clock.now().addingTimeInterval(3))
        #expect(d.segment != c.segment)
        await store.finishSegment()
        #expect(await store.activeSegmentPath == nil)
    }

    @Test("an interrupted fragmented segment is recovered; unreadable leftovers are marked broken")
    func recovery() async throws {
        let root = try TempDir.make()
        let crashDir = try TempDir.make()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: crashDir)
        }
        let clock = FakeClock()
        var config = FrameStore.Configuration.default
        config.fragmentInterval = 2
        config.keyFrameInterval = 2
        let store = FrameStore(root: root, configuration: config, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        var ref: FrameStore.FrameRef?
        for i in 0..<8 {
            ref = try await store.append(SyntheticImage.make(seed: i, size: 128), at: clock.now().addingTimeInterval(Double(i)))
        }
        // 给写入器一点时间把已完成的片段落盘，然后在不收尾的情况下拷走文件，模拟进程被杀。
        try await Task.sleep(for: .milliseconds(500))
        let part = root.appendingPathComponent(ref!.segment + ".part")
        let dayDir = crashDir.appendingPathComponent("2025-10-09")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: part, to: dayDir.appendingPathComponent(part.lastPathComponent))
        // 再放一个完全无法读取的残留。
        try Data("garbage".utf8).write(to: dayDir.appendingPathComponent("20251009_000000000.mp4.part"))

        let report = await FrameStore.recoverInterruptedSegments(in: crashDir)
        #expect(report.recovered == 1 && report.broken == 1)
        let recovered = dayDir.appendingPathComponent((ref!.segment as NSString).lastPathComponent)
        let image = try await FrameStore.image(segmentURL: recovered, frameIndex: 0)
        #expect(image.width == 128)
        #expect(FileManager.default.fileExists(atPath: dayDir.appendingPathComponent("20251009_000000000.mp4.broken").path))
        await store.finishSegment()
    }

    @Test("finishSegment without frames is a no-op")
    func emptyFinish() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FrameStore(root: root, clock: FakeClock())
        await store.finishSegment()
        #expect(await store.activeFrameCount == 0)
    }
}
