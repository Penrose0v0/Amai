import AmaiMemory
import Foundation

/// 记忆副本中所有可作为证据的条目，经由只读的 `MemoryAPI` 读取（与助手看到的是同一种解析结果）。
public struct EvidenceCatalog: Sendable {
    public let units: [QAEvidence]
    /// 有 daily 文件的日期（YYYY-MM-DD，升序）。
    public let days: [String]
    /// 整个副本归一化后的全文：校验"无法回答"的题所说的关键词确实不在记忆里。
    let corpus: String

    /// 太短的条目（"运动"）当不了证据。
    static let minimumCharacters = 6

    public init(units: [QAEvidence], days: [String], corpus: String) {
        self.units = units
        self.days = days
        self.corpus = corpus
    }

    public static func build(root: URL, timeZone: TimeZone = .current) throws -> EvidenceCatalog {
        let api = MemoryAPI(root: root, index: nil, access: .all, timeZone: timeZone)
        var units: [QAEvidence] = []
        func add(_ kind: QAEvidence.Kind, _ category: MemoryCategory, _ file: String, section: String? = nil,
                 date: String? = nil, time: String? = nil, text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard QAText.normalize(text).count >= minimumCharacters else { return }
            units.append(QAEvidence(
                id: String(format: "E%04d", units.count + 1), kind: kind, category: category, file: file,
                section: section, date: date, time: time, text: text
            ))
        }

        for category in MemoryCategory.documents {
            guard let memory = try api.memory(category) else { continue }
            for section in memory.sections {
                for entry in section.entries {
                    add(.item, category, memory.file, section: section.name, date: entry.sources.max(), text: entry.text)
                }
            }
            for line in noteLines(memory.userNotes) {
                add(.userNote, category, memory.file, text: line)
            }
        }

        let days = api.library.dailyDays().sorted()
        for day in days {
            let timeline = try api.timeline(on: day)
            guard timeline.exists else { continue }
            let file = "\(MemoryDirectory.dailyDirectory)/\(day).md"
            for entry in timeline.entries {
                let text = entry.summary.isEmpty ? entry.title : "\(entry.title) — \(entry.summary)"
                add(.timelineEntry, .daily, file, date: day, time: "\(entry.start)–\(entry.end)", text: text)
            }
            for line in noteLines(timeline.summary ?? "") {
                add(.daySummary, .daily, file, date: day, text: line)
            }
            for line in noteLines(timeline.userNotes) {
                add(.userNote, .daily, file, date: day, text: line)
            }
        }

        var corpus = ""
        for relative in QAWorkspace.memoryFiles(in: root) {
            corpus += QAText.normalize((try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? "")
        }
        return EvidenceCatalog(units: units, days: days, corpus: corpus)
    }

    /// 自由文本按行拆开，去掉列表符号与标题行。
    static func noteLines(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("<!--") else { return nil }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = String(line.dropFirst(2)) }
            return line.isEmpty ? nil : line
        }
    }

    /// 这个词（归一化后）是否出现在记忆副本的任何地方。
    public func mentions(_ term: String) -> Bool {
        let normalized = QAText.normalize(term)
        return !normalized.isEmpty && corpus.contains(normalized)
    }

    public func unit(_ id: String) -> QAEvidence? { units.first { $0.id == id } }
}
