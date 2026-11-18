import AppKit

/// 公式排版的占位。Eira 用 SwiftMath（一个 fork）把 LaTeX 排成图片；Amai 暂不为此引入新的依赖，
/// 所以这里始终返回 nil，消息气泡按原有的回退路径显示 LaTeX 原文。
/// 公式的扫描（`MathScanner`）原样保留，今后接入排版时只需实现这一个函数。
@MainActor
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        let ascent: CGFloat
        let descent: CGFloat
    }

    static func render(latex: String, fontSize: CGFloat, display: Bool, color: NSColor = .white) -> Rendered? {
        nil
    }
}

/// Finds math spans in raw assistant text. Runs *before* markdown parsing —
/// which is also what rescues `\(…\)`: AttributedString's markdown parser reads
/// `\(` as an escape and silently eats the delimiters.
enum MathScanner {
    enum Run {
        case text(String)
        case math(String)
    }

    /// Split prose into plain-text and inline-math (`$…$`, `\(…\)`) pieces.
    static func scanInline(_ s: String) -> [Run] {
        var runs: [Run] = []
        var buf = ""
        let c = Array(s)
        var i = 0

        func flushText() {
            if !buf.isEmpty { runs.append(.text(buf)); buf = "" }
        }

        while i < c.count {
            // \( … \)
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(",
               let end = escapedClose(c, from: i + 2, closer: ")") {
                let body = String(c[(i + 2)..<end])
                if isPlausible(body) {
                    flushText()
                    runs.append(.math(body))
                    i = end + 2
                    continue
                }
            }
            // $ … $  (`$$` blocks are handled upstream by the block parser)
            if c[i] == "$", i + 1 < c.count, c[i + 1] != "$",
               let end = dollarClose(c, from: i + 1) {
                let body = String(c[(i + 1)..<end])
                if isPlausible(body) {
                    flushText()
                    runs.append(.math(body))
                    i = end + 1
                    continue
                }
            }
            buf.append(c[i])
            i += 1
        }
        flushText()
        return runs
    }

    /// Index of the `\` in a closing `\)` / `\]`.
    private static func escapedClose(_ c: [Character], from: Int, closer: Character) -> Int? {
        var i = from
        while i + 1 < c.count {
            if c[i] == "\\", c[i + 1] == closer { return i }
            i += 1
        }
        return nil
    }

    /// Closing `$` of an inline span: same line, not preceded by a space. That
    /// last rule is what keeps prose like "$5 and $10" from reading as math.
    private static func dollarClose(_ c: [Character], from: Int) -> Int? {
        var i = from
        while i < c.count {
            if c[i] == "\n" { return nil }
            if c[i] == "$" {
                guard i > from, !c[i - 1].isWhitespace else { return nil }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Cheap sanity guard against currency/prose false positives. Anything that
    /// slips through but isn't valid LaTeX still fails in the renderer and falls
    /// back to source text, so this only needs to catch the obvious cases.
    private static func isPlausible(_ body: String) -> Bool {
        guard let first = body.first, !first.isWhitespace else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 400
    }

    /// A `$$ … $$` / `\[ … \]` display block starting at `lines[i]`. Returns the
    /// LaTeX body and the index to resume from. Streaming-safe: an unclosed
    /// opener typesets whatever has arrived so far.
    static func displayBlock(_ lines: [String], at i: Int) -> (latex: String, next: Int)? {
        let head = lines[i].trimmingCharacters(in: .whitespaces)
        let opener: String, closer: String
        if head.hasPrefix("$$") { opener = "$$"; closer = "$$" }
        else if head.hasPrefix("\\[") { opener = "\\["; closer = "\\]" }
        else { return nil }

        // Single-line form: `$$ x = 1 $$`
        let rest = String(head.dropFirst(opener.count))
        if let r = rest.range(of: closer, options: .backwards), r.upperBound == rest.endIndex {
            return (String(rest[rest.startIndex..<r.lowerBound])
                .trimmingCharacters(in: .whitespaces), i + 1)
        }

        // Multi-line: collect until the closer lands.
        var body = rest.isEmpty ? "" : rest + "\n"
        var j = i + 1
        while j < lines.count {
            if let r = lines[j].range(of: closer) {
                body += String(lines[j][lines[j].startIndex..<r.lowerBound])
                return (body.trimmingCharacters(in: .whitespacesAndNewlines), j + 1)
            }
            body += lines[j] + "\n"
            j += 1
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), j)
    }
}
