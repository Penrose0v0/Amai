import AmaiCore
import Foundation

/// 原始数据的短期缓冲（docs/architecture.md §2.1）。
///
/// 目录布局：
/// ```
/// raw/
/// └── YYYY-MM-DD/
///     ├── events.jsonl                    该日全部 PerceptionEvent，一行一个
///     ├── <yyyyMMdd_HHmmssSSS>_d<显示器>.mp4        截图帧的 HEVC 分段（FrameStore 写入，每块显示器一个）
///     ├── <yyyyMMdd_HHmmssSSS>_d<显示器>.mp4.part   写入中的分段，清理时跳过
///     └── <wallMs>-<id8>.<ext>            其他 payload（如音频块），文件名按时间排序
/// ```
/// 清理策略：
/// - TTL：整天目录的日期早于 `now - maxAge` 时整体删除；
/// - 容量：总字节超过 `maxBytes` 时按文件名顺序删除最旧的 payload，直到低于上限。
///   索引行保留，payload 缺失由消费方（抽取层）按"原始数据已过期"处理。
/// 重启恢复：初始化时重新统计字节数并立即执行一次清理。
public actor RawSpool {
    public let root: URL
    public private(set) var limits: RawSpoolLimits
    public private(set) var totalBytes: Int64 = 0

    private let clock: any AmaiClock
    private let timeZone: TimeZone
    private let log = AmaiLog.logger("perception.spool")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        root: URL,
        limits: RawSpoolLimits,
        clock: any AmaiClock = SystemClock(),
        timeZone: TimeZone = .current
    ) throws {
        self.root = root
        self.limits = limits
        self.clock = clock
        self.timeZone = timeZone

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let measured = Self.measure(root)
        totalBytes = measured
        log.info("spool opened, \(measured) bytes on disk")
    }

    public func updateLimits(_ limits: RawSpoolLimits) throws {
        self.limits = limits
        try purge()
    }

    /// 由 FrameStore 等直接写文件的组件在完成一个文件后报告字节数。
    public func noteExternalBytes(_ bytes: Int64) throws {
        totalBytes += bytes
        if totalBytes > limits.maxBytes {
            try purge()
        }
    }

    // MARK: - Append

    /// 写入 payload（可为空）并追加索引行。返回带 `payloadRef` 的事件副本。
    @discardableResult
    public func append(_ event: PerceptionEvent, payload: Data?, payloadExtension: String = "jpg") throws -> PerceptionEvent {
        let dayDir = root.appendingPathComponent(dayName(for: event.wallTime), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        var stored = event
        if let payload {
            let name = Self.payloadName(for: event, ext: payloadExtension)
            let url = dayDir.appendingPathComponent(name)
            try payload.write(to: url, options: .atomic)
            totalBytes += Int64(payload.count)
            stored = PerceptionEvent(
                id: event.id,
                wallTime: event.wallTime,
                monoTime: event.monoTime,
                source: event.source,
                kind: event.kind,
                payloadRef: "\(dayDir.lastPathComponent)/\(name)",
                metadata: event.metadata,
                sensitivity: event.sensitivity
            )
        }

        var line = try encoder.encode(stored)
        line.append(0x0A)
        let indexURL = dayDir.appendingPathComponent("events.jsonl")
        try Self.appendLine(line, to: indexURL)
        totalBytes += Int64(line.count)

        if totalBytes > limits.maxBytes {
            try purge()
        }
        return stored
    }

    // MARK: - Read

    /// 读取某一天的全部事件（按写入顺序）。损坏的行跳过并计数。
    public func events(on date: Date) throws -> [PerceptionEvent] {
        let indexURL = root
            .appendingPathComponent(dayName(for: date), isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        var result: [PerceptionEvent] = []
        var corrupt = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let event = try? decoder.decode(PerceptionEvent.self, from: line) {
                result.append(event)
            } else {
                corrupt += 1
            }
        }
        if corrupt > 0 {
            log.error("spool index has \(corrupt) unreadable lines for \(indexURL.lastPathComponent, privacy: .public)")
        }
        return result
    }

    public func payloadURL(for event: PerceptionEvent) -> URL? {
        guard let ref = event.payloadRef else { return nil }
        let url = root.appendingPathComponent(ref)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Purge

    /// 先按 TTL 删整天目录，再按容量删最旧 payload。
    public func purge() throws {
        let fm = FileManager.default
        let cutoffDay = dayName(for: clock.now().addingTimeInterval(-limits.maxAge))
        var removedDays = 0
        for dir in try dayDirectories() where dir.lastPathComponent < cutoffDay {
            try fm.removeItem(at: dir)
            removedDays += 1
        }
        if removedDays > 0 {
            totalBytes = Self.measure(root)
        }

        var removedFiles = 0
        if totalBytes > limits.maxBytes {
            for file in try payloadFilesOldestFirst() {
                guard totalBytes > limits.maxBytes else { break }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                try fm.removeItem(at: file)
                totalBytes -= size
                removedFiles += 1
            }
        }
        if removedDays > 0 || removedFiles > 0 {
            log.info("spool purge: removed \(removedDays) day(s), \(removedFiles) payload(s); now \(self.totalBytes) bytes")
        }
    }

    // MARK: - Erase

    /// 删除时间段内的原始数据：时间段内的索引行全部删除；与时间段有重叠的视频分段整段删除
    ///（分段无法局部裁剪，宁可多删）。写入中的分段（`.part`）由调用方先结束再删。
    /// 返回删除的 payload 文件数。
    @discardableResult
    public func erase(from start: Date, to end: Date) throws -> Int {
        let fm = FileManager.default
        var removedFiles = 0
        for dir in try dayDirectories() {
            let indexURL = dir.appendingPathComponent("events.jsonl")
            guard let data = try? Data(contentsOf: indexURL) else { continue }
            var kept = Data()
            var doomedRefs = Set<String>()
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let event = try? decoder.decode(PerceptionEvent.self, from: line) else {
                    kept.append(line); kept.append(0x0A); continue
                }
                if event.wallTime >= start && event.wallTime <= end {
                    if let ref = event.payloadRef { doomedRefs.insert(ref) }
                } else {
                    kept.append(line); kept.append(0x0A)
                }
            }
            guard kept.count != data.count || !doomedRefs.isEmpty else { continue }
            try kept.write(to: indexURL, options: .atomic)
            for ref in doomedRefs {
                let url = root.appendingPathComponent(ref)
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                    removedFiles += 1
                }
            }
        }
        totalBytes = Self.measure(root)
        log.info("erase removed \(removedFiles) payload file(s)")
        return removedFiles
    }

    // MARK: - Helpers

    private func dayName(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func payloadName(for event: PerceptionEvent, ext: String) -> String {
        let ms = Int64(event.wallTime.timeIntervalSince1970 * 1000)
        let short = event.id.uuidString.prefix(8).lowercased()
        return String(format: "%013lld-%@.%@", ms, String(short), ext)
    }

    private func dayDirectories() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func payloadFilesOldestFirst() throws -> [URL] {
        var files: [URL] = []
        for dir in try dayDirectories() {
            let items = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )
            files += items
                .filter { $0.lastPathComponent != "events.jsonl" && $0.pathExtension != "part" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return files
    }

    private static func measure(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func appendLine(_ line: Data, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }
}
