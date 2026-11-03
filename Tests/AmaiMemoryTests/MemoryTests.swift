import AmaiCore
import Foundation
import GRDB
import Testing
@testable import AmaiMemory

let utc = TimeZone(identifier: "UTC")!
/// 2026-10-19T03:00:00Z
let base = Date(timeIntervalSince1970: 1_792_378_800)
func at(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

func segment(
    _ start: TimeInterval, _ end: TimeInterval, _ title: String,
    summary: String = "", category: ActivityCategory = .work, confidence: Double = 0.9,
    provider: String = "mlx:test", id: UUID = UUID(), updatedAt: Date? = nil, observations: [UUID] = []
) -> ActivitySegment {
    ActivitySegment(
        id: id, timeRange: TimeRange(start: at(start), end: at(end)), title: title, summary: summary,
        category: category, apps: [], observations: observations, confidence: confidence, provider: provider,
        updatedAt: updatedAt ?? at(end)
    )
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("amai-memory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MemoryDirectory")
struct MemoryDirectoryTests {
    @Test("daily file name uses the given time zone")
    func dailyFileName() throws {
        // 2026-10-19 23:30 东京时间 = 2026-10-19 14:30 UTC
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 19
        components.hour = 23; components.minute = 30
        components.timeZone = tokyo
        let date = try #require(Calendar(identifier: .gregorian).date(from: components))
        #expect(MemoryDirectory.dailyFile(for: date, timeZone: tokyo) == "daily/2026-10-19.md")
        let auckland = try #require(TimeZone(identifier: "Pacific/Auckland"))
        #expect(MemoryDirectory.dailyFile(for: date, timeZone: auckland) == "daily/2026-10-20.md")
    }

    @Test("daily file path parses back to its day")
    func parseDay() {
        #expect(MemoryDirectory.day(ofDailyFile: "daily/2026-10-20.md", timeZone: utc) == Date(timeIntervalSince1970: 1_792_454_400))
        #expect(MemoryDirectory.day(ofDailyFile: "work/research.md", timeZone: utc) == nil)
    }

    @Test("default root is ~/.amai/memory and config expands tilde")
    func defaults() throws {
        #expect(MemoryDirectory.defaultRootURL.path.hasSuffix("/.amai/memory"))
        #expect(MemoryConfiguration.default.rootURL.path == MemoryDirectory.defaultRootURL.path)
        #expect(throws: MemoryConfiguration.ValidationError.relativeRoot("memory")) {
            try MemoryConfiguration(root: "memory").validate()
        }
    }
}

@Suite("TimelineBlock")
struct TimelineBlockTests {
    @Test("renders sorted lines with stable ids; skips idle and privacy; tags low confidence")
    func render() {
        let a = segment(600, 900, "查阅文档", summary: "在 Safari 中阅读")
        let b = segment(0, 500, "编辑采集代码", summary: "在 Xcode 中\n编辑 <!-- x --> 代码")
        let idle = segment(900, 1200, "离开电脑", category: .idle, provider: "rule:idle")
        let privacy = segment(1200, 1300, "隐私跳过：密码输入", category: .other, provider: "rule:privacy")
        let low = segment(1300, 1600, "使用 Xcode", confidence: 0.3, provider: "fallback:metadata")

        let body = TimelineBlock.render([a, b, idle, privacy, low], timeZone: utc)
        let lines = body.split(separator: "\n").map(String.init)
        #expect(lines.first == "- 03:00–03:08 编辑采集代码 <!-- seg:\(b.id.uuidString) conf:0.90 src:mlx:test -->")
        #expect(lines[1] == "  在 Xcode 中 编辑  x  代码")
        #expect(body.contains("seg:\(a.id.uuidString)"))
        #expect(!body.contains("离开电脑"))
        #expect(!body.contains("隐私跳过"))
        #expect(body.contains("\(TimelineBlock.lowConfidenceTag)使用 Xcode"))
        #expect(body.firstRange(of: "编辑采集代码")!.lowerBound < body.firstRange(of: "查阅文档")!.lowerBound)
    }

    @Test("splice creates a new file, replaces only the block, and appends when markers are gone")
    func splice() throws {
        let created = try TimelineBlock.splice(body: "- A", into: nil, dayTitle: "2026-10-20")
        #expect(created.hasPrefix("# 2026-10-20\n\n## 时间线\n\n<!-- amai:timeline:begin"))
        #expect(created.contains("- A\n<!-- amai:timeline:end -->"))

        let edited = created + "\n## 我的笔记\n今天状态不错。\n"
        let replaced = try TimelineBlock.splice(body: "- B", into: edited, dayTitle: "2026-10-20")
        #expect(replaced.contains("- B"))
        #expect(!replaced.contains("- A"))
        #expect(replaced.hasSuffix("## 我的笔记\n今天状态不错。\n"))
        #expect(try TimelineBlock.splice(body: "- B", into: replaced, dayTitle: "x") == replaced)

        let noBlock = "# 手写的一天\n\n随便写写\n"
        let appended = try TimelineBlock.splice(body: "- C", into: noBlock, dayTitle: "x")
        #expect(appended.hasPrefix(noBlock))
        #expect(appended.contains("## 时间线\n\n<!-- amai:timeline:begin"))
    }

    @Test("malformed markers refuse to write")
    func malformed() {
        let broken = "# x\n<!-- amai:timeline:begin -->\n- 半截\n"
        #expect(throws: TimelineBlock.SpliceError.malformedMarkers) {
            try TimelineBlock.splice(body: "- A", into: broken, dayTitle: "x")
        }
        let reversed = "<!-- amai:timeline:end -->\n<!-- amai:timeline:begin -->"
        #expect(throws: TimelineBlock.SpliceError.malformedMarkers) {
            try TimelineBlock.splice(body: "- A", into: reversed, dayTitle: "x")
        }
    }
}

@Suite("MemoryStore")
struct MemoryStoreTests {
    @Test("writes the daily timeline, preserves user edits outside the block, and is idempotent")
    func dailyTimeline() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MemoryStore(root: root, timeZone: utc)

        // 只有空闲片段：不创建文件。
        #expect(try await store.writeDailyTimeline(day: at(0), segments: [segment(0, 300, "离开", category: .idle)]) == false)
        #expect(await store.read("daily/2026-10-19.md") == nil)

        let s1 = segment(0, 500, "编辑采集代码")
        #expect(try await store.writeDailyTimeline(day: at(0), segments: [s1]))
        let url = root.appendingPathComponent("daily/2026-10-19.md")
        let userEdit = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "## 时间线", with: "## 心情\n有点累\n\n## 时间线")
        try userEdit.write(to: url, atomically: true, encoding: .utf8)

        // 片段延续：同一 id 时间变长、标题变化。
        let s1b = segment(0, 1400, "编辑并测试采集代码", id: s1.id)
        #expect(try await store.writeDailyTimeline(day: at(0), segments: [s1b]))
        let text = try #require(await store.read("daily/2026-10-19.md"))
        #expect(text.contains("## 心情\n有点累"))
        #expect(text.contains("编辑并测试采集代码"))
        #expect(!text.contains("- 03:00–03:08 编辑采集代码"))
        #expect(text.components(separatedBy: "seg:\(s1.id.uuidString)").count == 2)

        #expect(try await store.writeDailyTimeline(day: at(0), segments: [s1b]) == false)
        // 片段被删除后区块清空，用户内容仍在。
        #expect(try await store.writeDailyTimeline(day: at(0), segments: []))
        let emptied = try #require(await store.read("daily/2026-10-19.md"))
        #expect(!emptied.contains("seg:"))
        #expect(emptied.contains("有点累"))
    }

    @Test("lists markdown files relative to the root")
    func listFiles() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MemoryStore(root: root, timeZone: utc)
        try "x".write(to: root.appendingPathComponent("general.md"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
        try "z".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        // 归档目录是隐藏目录，不参与索引与整理。
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".archive/schema-v1"), withIntermediateDirectories: true)
        try "old".write(to: root.appendingPathComponent(".archive/schema-v1/summary.md"), atomically: true, encoding: .utf8)
        #expect(await store.markdownFiles() == ["general.md", "work.md"])
    }
}

@Suite("MarkdownSections")
struct MarkdownSectionsTests {
    @Test("splits by level-2 headings and strips comments")
    func parse() {
        let text = """
        # 2026-10-20

        ## 时间线

        <!-- amai:timeline:begin · 说明 -->
        - 11:00–11:30 写代码 <!-- seg:ABC conf:0.9 src:x -->
        <!-- amai:timeline:end -->

        ## 笔记
        ```
        ## 不是标题
        ```
        """
        let sections = MarkdownSections.parse(text)
        #expect(sections.map(\.heading) == ["", "时间线", "笔记"])
        #expect(sections[1].content == "- 11:00–11:30 写代码")
        #expect(sections[2].content.contains("## 不是标题"))
    }
}

@Suite("MemoryIndex")
struct MemoryIndexTests {
    struct Fixture {
        let root: URL
        let index: MemoryIndex

        init() throws {
            root = try tempDir()
            try MemoryDirectory.ensureDirectories(at: root)
            index = MemoryIndex(root: root, database: try MemoryIndexDatabase.inMemory(), timeZone: utc)
        }

        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    @Test("Chinese retrieval works for long (FTS) and two-character (substring) queries")
    func chinese() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("daily/2026-10-19.md", "# 2026-10-20\n\n## 时间线\n- 03:00–03:08 编辑采集代码并调试屏幕录制权限\n")
        try f.write("work.md", "# Work\n\n## 当前方向\n多智能体一致性评估\n")
        #expect(try await f.index.refresh().indexed == 2)

        let long = try await f.index.retrieve("屏幕录制")
        #expect(long.map(\.file) == ["daily/2026-10-19.md"])
        #expect(long.first?.heading == "时间线")
        #expect(long.first?.excerpt.contains("屏幕录制") == true)

        let short = try await f.index.retrieve("代码")
        #expect(short.map(\.file) == ["daily/2026-10-19.md"])

        let work = try await f.index.retrieve("一致性", categories: [.work])
        #expect(work.map(\.file) == ["work.md"])
        #expect(work.first?.category == .work)
        #expect(try await f.index.retrieve("一致性", categories: [.daily, .general]).isEmpty)
        #expect(try await f.index.retrieve("一致性", categories: []).isEmpty)
    }

    @Test("day range filters daily files")
    func dayRange() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("daily/2026-10-19.md", "## 时间线\n- 阅读论文初稿\n")
        try f.write("daily/2026-10-20.md", "## 时间线\n- 阅读论文修改稿\n")
        try await f.index.refresh()
        let day20 = Date(timeIntervalSince1970: 1_792_454_400)
        let hits = try await f.index.retrieve("阅读论文", dayRange: day20...day20)
        #expect(hits.map(\.file) == ["daily/2026-10-20.md"])
    }

    @Test("refresh picks up user edits and deletions; rebuild matches")
    func incremental() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("general.md", "# General\n\n## 习惯\n早上写代码\n")
        try f.write("goals.md", "## 本周\n完成 M3\n")
        try await f.index.refresh()
        #expect(try await f.index.refresh() == .init(indexed: 0, removed: 0, unchanged: 2))

        try f.write("general.md", "# General\n\n## 习惯\n晚上散步，早上写代码\n")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("goals.md"))
        let r = try await f.index.refresh()
        #expect(r.indexed == 1 && r.removed == 1)
        #expect(try await f.index.retrieve("晚上散步").map(\.file) == ["general.md"])
        #expect(try await f.index.retrieve("完成 M3").isEmpty)

        let before = try await f.index.retrieve("写代码")
        try await f.index.rebuild()
        #expect(try await f.index.retrieve("写代码") == before)
    }
}

final class FakeSource: SegmentSource, @unchecked Sendable {
    private let lock = NSLock()
    var byDay: [Date: [ActivitySegment]] = [:]
    var facts: [Observation] = []

    func set(_ segments: [ActivitySegment], on day: Date) { lock.withLock { byDay[day] = segments } }

    /// 一条采集元数据观察（前台应用），返回其 id 供片段引用。
    func addFact(app: String, at time: TimeInterval) -> UUID {
        let o = Observation(
            timeRange: TimeRange(start: at(time), end: at(time + 10)), modality: .screen, kind: .fact,
            content: "屏幕文字不应进入记忆", confidence: 1, evidence: [], attributes: ["app": app], provider: "perception"
        )
        lock.withLock { facts.append(o) }
        return o.id
    }

    func observations(on day: Date) async -> [Observation] { lock.withLock { facts } }

    func daysWithUpdates(after: Date?, endingOn: Date, days: Int) async -> [(day: Date, latestUpdate: Date)] {
        lock.withLock {
            byDay.compactMap { day, segs in
                let latest = segs.map(\.updatedAt).filter { after == nil || $0 > after! }.max()
                return latest.map { (day, $0) }
            }
        }
    }

    func segments(on day: Date) async -> [ActivitySegment] {
        lock.withLock {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = utc
            return byDay[cal.startOfDay(for: day)] ?? []
        }
    }
}

final class FixedClock: AmaiClock, @unchecked Sendable {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
    func monotonicNanoseconds() -> UInt64 { 1 }
}

@Suite("MemorySync")
struct MemorySyncTests {
    @Test("syncs updated days, advances the watermark, re-renders on updates, survives restart")
    func sync() async throws {
        let root = try tempDir()
        let stateDir = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: stateDir)
        }
        let day = Date(timeIntervalSince1970: 1_792_368_000)
        let source = FakeSource()
        let s1 = segment(0, 600, "编辑采集代码", updatedAt: at(700))
        source.set([s1], on: day)

        func makeSync() throws -> MemorySync {
            let store = try MemoryStore(root: root, timeZone: utc)
            let index = MemoryIndex(root: root, database: try MemoryIndexDatabase.inMemory(), timeZone: utc)
            return MemorySync(
                source: source, store: store, index: index,
                stateURL: stateDir.appendingPathComponent("memory-sync.json"), clock: FixedClock(at(3600))
            )
        }

        let sync = try makeSync()
        #expect(await sync.syncOnce() == 1)
        #expect(await sync.status.watermark == at(700))
        #expect(await sync.syncOnce() == 0)

        let s1b = segment(0, 1400, "编辑并测试采集代码", id: s1.id, updatedAt: at(1500))
        source.set([s1b], on: day)
        #expect(await sync.syncOnce() == 1)
        let text = try String(contentsOf: root.appendingPathComponent("daily/2026-10-19.md"), encoding: .utf8)
        #expect(text.contains("编辑并测试采集代码"))

        // 重启后水位线从磁盘恢复，不重复写入。
        let restarted = try makeSync()
        #expect(await restarted.status.watermark == at(1500))
        #expect(await restarted.syncOnce() == 0)
    }
}
