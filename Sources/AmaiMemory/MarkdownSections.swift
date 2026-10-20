import Foundation

/// 把 Markdown 切成以二级标题为单位的 section，供索引使用（docs/memory.md §3.1）。
/// 第一个 `##` 之前的内容（一级标题、前言）作为 heading 为空的 section。
/// 系统区块标记与片段 ID 注释在索引文本中去掉，不参与检索。
enum MarkdownSections {
    struct Section: Equatable {
        let heading: String
        let content: String
        let position: Int
    }

    static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        var heading = ""
        var lines: [Substring] = []
        var inFence = false

        func flush() {
            let content = clean(lines.joined(separator: "\n"))
            if !content.isEmpty || !heading.isEmpty {
                sections.append(Section(heading: heading, content: content, position: sections.count))
            }
            lines = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                flush()
                heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    private static let commentRegex = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])

    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return commentRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
