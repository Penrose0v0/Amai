import AmaiCore
import Foundation
@testable import AmaiExtraction

let utc = TimeZone(identifier: "UTC")!
/// 2026-10-19T03:00:00Z
let base = Date(timeIntervalSince1970: 1_792_378_800)

func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

func frame(
    _ t: TimeInterval,
    app: String = "Xcode",
    bundle: String = "com.apple.dt.Xcode",
    idle: Double = 2,
    duplicateOf: UUID? = nil,
    index: Int = 0,
    segment: String = "2026-10-20/seg.mp4"
) -> PerceptionEvent {
    PerceptionEvent(
        wallTime: at(t), monoTime: UInt64(t * 1e9) + 1,
        source: .screen, kind: .screenFrame, payloadRef: segment,
        metadata: PerceptionMetadata(app: app, bundleId: bundle, idleSeconds: idle, duplicateOf: duplicateOf, frameIndex: index)
    )
}

func skipped(_ t: TimeInterval, reason: String = "secureInput") -> PerceptionEvent {
    PerceptionEvent(
        wallTime: at(t), monoTime: UInt64(t * 1e9) + 1,
        source: .screen, kind: .screenFrame, payloadRef: nil,
        metadata: PerceptionMetadata(idleSeconds: 1, skipReason: reason), sensitivity: .skipped
    )
}

/// 每 10 秒一帧，从 `start` 到 `end`（含）。
func frames(_ start: TimeInterval, _ end: TimeInterval, app: String = "Xcode", bundle: String = "com.apple.dt.Xcode", idle: Double = 2, firstIndex: Int = 0) -> [PerceptionEvent] {
    stride(from: start, through: end, by: 10).enumerated().map { i, t in
        frame(t, app: app, bundle: bundle, idle: idle, index: firstIndex + i)
    }
}

final class TestClock: AmaiClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func monotonicNanoseconds() -> UInt64 { 1 }
    func set(_ d: Date) { lock.withLock { date = d } }
}

final class FakeReader: PerceptionReading, @unchecked Sendable {
    private let lock = NSLock()
    var events: [PerceptionEvent]
    var availability: FrameAvailability = .available(Data([0xFF, 0xD8, 0xFF]))
    private(set) var frameRequests = 0

    init(events: [PerceptionEvent]) { self.events = events }

    func events(after: Date, until: Date) async throws -> [PerceptionEvent] {
        lock.withLock { events.filter { $0.wallTime > after && $0.wallTime <= until } }
    }

    func frame(payloadRef: String, frameIndex: Int, maxHeight: Int) async -> FrameAvailability {
        lock.withLock {
            frameRequests += 1
            return availability
        }
    }
}

final class FakeOCR: TextRecognizer, @unchecked Sendable {
    var text = "ScreenFrameSource.swift\nfunc captureFrame"
    func recognize(jpeg: Data) async throws -> OCRResult {
        OCRResult(lines: text.split(separator: "\n").map { OCRLine(text: String($0), confidence: 0.9) })
    }
}

/// 根据请求类型返回脚本化输出：带图片的是帧描述，不带图片的是活动切分。
final class FakeModel: ModelProvider, @unchecked Sendable {
    let identifier = "fake:vlm"
    let sendsDataOffDevice = false
    private let lock = NSLock()
    var describe: String = "在 Xcode 中编辑 ScreenFrameSource.swift"
    var segmentation: [String] = []
    var error: Error?
    private(set) var describeCalls = 0
    private(set) var segmentCalls = 0
    private(set) var lastSegmentPrompt = ""

    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        try lock.withLock {
            if let error { throw error }
            if request.images.isEmpty {
                segmentCalls += 1
                lastSegmentPrompt = request.dynamic
                let text = segmentation.isEmpty ? "[]" : segmentation.removeFirst()
                return ModelResponse(text: text, provider: identifier, latencyMs: 1)
            }
            describeCalls += 1
            return ModelResponse(text: describe, provider: identifier, latencyMs: 1)
        }
    }
}

enum TempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amai-extraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 03:00:00 起的时刻 → "HH:MM:SS"（UTC）。
func hms(_ seconds: TimeInterval) -> String {
    let total = 3 * 3600 + Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
