import AmaiAssistant
import AmaiMemory
import SwiftUI
import AppKit

/// 一条聊天消息的显示（移植自 Eira）：用户消息是气泡，助手回复是直接排在面板上的 Markdown
///（代码块、表格、引用、标题）。Amai 增加了回答下方的记忆来源。公式不排版，显示 LaTeX 原文。
struct MessageBubble: View {
    let message: ChatItem
    /// 点击某个记忆来源。
    var onOpenSource: ((MemorySource) -> Void)? = nil
    /// 回答下方显示复制等按钮（正在生成的那条不显示）。
    var showsActions = true
    /// 重新生成这条回答（只有最后一条回答提供）。
    var onRegenerate: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch message.role {
            case .user:
                Spacer(minLength: 50)
                userBubble
            case .assistant:
                assistantBubble
                Spacer(minLength: 0)
            case .system:
                systemBubble
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - User

    // User content rarely contains code; render plain to keep the bubble tight.
    // Shows an attached image above the text; blue translucent bubble.
    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .bubbleGlass(tint: Color.blue.opacity(0.25))
    }

    // MARK: - Assistant

    // No bubble background — LLM output renders as plain text on the panel.
    @ViewBuilder
    private var assistantBubble: some View {
        if message.content.isEmpty {
            Text(verbatim: message.activity ?? "•••")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.parse(message.content)) { segment in
                    render(segment)
                }
                if let activity = message.activity {
                    Text(verbatim: activity)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !message.sources.isEmpty {
                    SourceChips(sources: message.sources, onOpen: onOpenSource)
                }
                if showsActions, message.activity == nil {
                    actionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 回答下方的操作：复制整条回答（Markdown 原文），最后一条还可以重新生成。
    private var actionRow: some View {
        HStack(spacing: 2) {
            actionButton(
                copied ? "checkmark" : "doc.on.doc",
                help: copied ? String(localized: "已复制") : String(localized: "复制")
            ) { copyAnswer() }
            if let onRegenerate {
                actionButton("arrow.clockwise", help: String(localized: "重新生成"), action: onRegenerate)
            }
        }
        .padding(.top, -2)
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }

    private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            copied = false
        }
    }

    @ViewBuilder
    private func render(_ segment: Segment) -> some View {
        switch segment.kind {
        case .text(let raw):
            Self.inlineText(raw, fontSize: 13)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let code):
            CodeBlock(language: language, code: code)

        case .math(let latex):
            MathBlock(latex: latex)

        case .blockquote(let raw):
            Self.inlineText(raw, fontSize: 13)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 3)
                }

        case .heading(let level, let text):
            Text(Self.attributedText(text))
                .textSelection(.enabled)
                .font(.system(size: Self.headingFontSize(level), weight: .semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)

        case .table(let header, let aligns, let rows):
            TableView(header: header, aligns: aligns, rows: rows)
        }
    }

    /// Heading font size by level. Levels 4-6 share level-3 size.
    private static func headingFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 15
        default: return 13.5
        }
    }

    // MARK: - System

    private var systemBubble: some View {
        Text(message.content)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Inline markdown helper

    fileprivate static func attributedText(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(raw)
    }

    /// Prose with inline math (`$…$`, `\(…\)`) typeset in place. Math is spliced
    /// in as `Text(Image)` rather than laid out in an HStack so the line keeps
    /// wrapping normally around it. Math is scanned before markdown runs — the
    /// markdown parser would otherwise eat `\(`'s backslash.
    @MainActor
    fileprivate static func inlineText(_ raw: String, fontSize: CGFloat) -> Text {
        var out = Text("")
        for run in MathScanner.scanInline(raw) {
            switch run {
            case .text(let s):
                out = out + Text(attributedText(s))
            case .math(let latex):
                if let r = MathRenderer.render(latex: latex, fontSize: fontSize, display: false) {
                    // Drop the glyph so its own baseline sits on the text baseline.
                    out = out + Text(Image(nsImage: r.image)).baselineOffset(-r.descent)
                } else {
                    // Unsupported glyphs or invalid LaTeX — show the source.
                    out = out + Text(verbatim: "$\(latex)$")
                }
            }
        }
        return out
    }

    // MARK: - Segments

    fileprivate struct Segment: Identifiable {
        let id: Int
        let kind: Kind

        enum Kind {
            case text(String)
            case code(language: String?, content: String)
            case blockquote(String)
            case heading(level: Int, text: String)
            case table(header: [String], aligns: [ColumnAlign], rows: [[String]])
            /// A `$$ … $$` / `\[ … \]` display formula on its own.
            case math(String)
        }
    }

    /// Per-column alignment parsed from a GFM table's delimiter row
    /// (`:---` left, `:--:` center, `---:` right).
    fileprivate enum ColumnAlign {
        case leading, center, trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
        var text: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    /// Split content into text / code / blockquote / heading / table segments.
    /// Streaming-safe: an unclosed ``` is still rendered as a code block, and a
    /// half-arrived table (header before its delimiter row has streamed in) just
    /// renders as text until the delimiter lands on a later token.
    fileprivate static func parse(_ content: String) -> [Segment] {
        var segments: [Segment] = []
        var textBuf = ""
        var codeBuf = ""
        var quoteBuf = ""
        var codeLang: String?
        var inCode = false

        func flushText() {
            let trimmed = textBuf.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                segments.append(Segment(id: segments.count, kind: .text(trimmed)))
            }
            textBuf = ""
        }

        func flushCode() {
            let body = codeBuf.hasSuffix("\n") ? String(codeBuf.dropLast()) : codeBuf
            if !body.isEmpty {
                segments.append(Segment(id: segments.count, kind: .code(language: codeLang, content: body)))
            }
            codeBuf = ""
            codeLang = nil
        }

        func flushQuote() {
            let trimmed = quoteBuf.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                segments.append(Segment(id: segments.count, kind: .blockquote(trimmed)))
            }
            quoteBuf = ""
        }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushText()
                    flushQuote()
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
                i += 1
                continue
            }

            if inCode {
                codeBuf += line + "\n"
                i += 1
                continue
            }

            // Display math: `$$ … $$` / `\[ … \]` occupying its own block.
            if let block = MathScanner.displayBlock(lines, at: i) {
                flushText()
                flushQuote()
                segments.append(Segment(id: segments.count, kind: .math(block.latex)))
                i = block.next
                continue
            }

            // Table: a `|`-bearing header row immediately followed by a
            // delimiter row (`|---|:--:|`). Matching column counts are required
            // so a stray pipe in prose doesn't get mistaken for a header.
            if i + 1 < lines.count,
               lineHasPipe(line),
               let aligns = tableDelimiter(lines[i + 1]) {
                let header = tableCells(line)
                if header.count == aligns.count, !header.isEmpty {
                    flushText()
                    flushQuote()
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.count,
                          lineHasPipe(lines[j]),
                          tableDelimiter(lines[j]) == nil {
                        rows.append(normalizeRow(tableCells(lines[j]), to: header.count))
                        j += 1
                    }
                    segments.append(Segment(
                        id: segments.count,
                        kind: .table(header: header, aligns: aligns, rows: rows)
                    ))
                    i = j
                    continue
                }
            }

            // Blockquote: line starts with ">" (optionally followed by space).
            if line.hasPrefix(">") {
                flushText()
                let stripped: String = {
                    let after = line.dropFirst()
                    return after.first == " " ? String(after.dropFirst()) : String(after)
                }()
                if !quoteBuf.isEmpty { quoteBuf += "\n" }
                quoteBuf += stripped
                i += 1
                continue
            }

            // Heading: 1-6 `#` followed by a space and text.
            if let (level, headingText) = parseHeading(line) {
                flushQuote()
                flushText()
                segments.append(Segment(
                    id: segments.count,
                    kind: .heading(level: level, text: headingText)
                ))
                i += 1
                continue
            }

            // Plain text line: any pending quote ends here.
            flushQuote()
            textBuf += line + "\n"
            i += 1
        }

        if inCode {
            flushCode()
        } else {
            flushQuote()
            flushText()
        }
        return segments
    }

    // MARK: - Table parsing

    /// A non-empty line containing at least one cell separator.
    private static func lineHasPipe(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Split a table row into trimmed cells, dropping the optional outer pipes
    /// and honoring escaped `\|` inside a cell.
    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let sentinel = "\u{0001}"
        s = s.replacingOccurrences(of: "\\|", with: sentinel)
        return s.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: sentinel, with: "|")
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// If `line` is a valid GFM delimiter row, return one alignment per column;
    /// otherwise nil. Each cell must be `:?-+:?` (at least one dash).
    private static func tableDelimiter(_ line: String) -> [ColumnAlign]? {
        guard lineHasPipe(line), line.contains("-") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [ColumnAlign] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return nil }
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            var core = c
            if left { core.removeFirst() }
            if right, !core.isEmpty { core.removeLast() }
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            aligns.append(left && right ? .center : right ? .trailing : .leading)
        }
        return aligns
    }

    /// Pad short rows / clip long ones so every body row matches the header.
    private static func normalizeRow(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    /// Match `#`, `##`, ..., `######` followed by at least one space.
    /// Returns (level, heading text) or nil. ATX-style only — no setext underlines.
    private static func parseHeading(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        // Must be followed by a space; otherwise it's `#tag` etc., not a heading.
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let text = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }
}

// MARK: - CodeBlock

/// A display formula on its own line. Falls back to the LaTeX source when the
/// formula holds glyphs SwiftMath can't set (CJK) or doesn't parse — mid-stream
/// a half-arrived formula routinely doesn't, and recovers on the next token.
private struct MathBlock: View {
    let latex: String

    var body: some View {
        if let rendered = MathRenderer.render(latex: latex, fontSize: 15, display: true) {
            Image(nsImage: rendered.image)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        } else {
            Text(verbatim: latex)
                .textSelection(.enabled)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if language != nil || hovering {
                HStack(spacing: 6) {
                    if let language, !language.isEmpty {
                        Text(language.lowercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Button {
                            copy()
                        } label: {
                            Label(copied ? "已复制" : "复制",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            Text(code)
                .textSelection(.enabled)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, language == nil && !hovering ? 8 : 4)
                .padding(.bottom, 8)
        }
        .background(
            Color.black.opacity(0.30),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - TableView

/// Renders a GFM table. Columns share width equally and wrap their text, so a
/// wide table can never overflow the chat bubble horizontally. Inline markdown
/// inside cells is honored; cell text is selectable like the rest of a reply.
private struct TableView: View {
    let header: [String]
    let aligns: [MessageBubble.ColumnAlign]
    let rows: [[String]]

    private var columnCount: Int { max(1, header.count) }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 7) {
            GridRow {
                ForEach(0 ..< columnCount, id: \.self) { c in
                    cell(header[safe: c] ?? "", col: c, isHeader: true)
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(0 ..< columnCount, id: \.self) { c in
                        cell(rows[r][safe: c] ?? "", col: c, isHeader: false)
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func cell(_ raw: String, col: Int, isHeader: Bool) -> some View {
        let align = aligns[safe: col] ?? .leading
        Text(MessageBubble.attributedText(raw))
            .font(.system(size: 12.5, weight: isHeader ? .semibold : .regular))
            .multilineTextAlignment(align.text)
            .textSelection(.enabled)
            .frame(
                maxWidth: .infinity,
                alignment: Alignment(horizontal: align.horizontal, vertical: .top)
            )
    }
}

private extension Array {
    /// Bounds-checked subscript — cells/aligns may be ragged after parsing.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Sources

/// 回答下方的记忆来源：这一轮工具调用实际读过的记忆文件与日期。点击在主窗口中打开。
private struct SourceChips: View {
    let sources: [MemorySource]
    let onOpen: ((MemorySource) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("记忆来源")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(sources.prefix(8)) { source in
                    Button { onOpen?(source) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: source.category == .daily ? "calendar" : "doc.text")
                                .font(.system(size: 9))
                            Text(verbatim: Self.label(source))
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(source.file)
                }
            }
        }
        .padding(.top, 2)
    }

    static func label(_ source: MemorySource) -> String {
        var parts = [source.category == .daily ? (source.date ?? source.category.localizedName) : source.category.localizedName]
        if let section = source.section, !section.isEmpty { parts.append(section) }
        if source.category != .daily, let date = source.date { parts.append(date) }
        return parts.joined(separator: " · ")
    }
}

/// 自动换行的横向排列。
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}
