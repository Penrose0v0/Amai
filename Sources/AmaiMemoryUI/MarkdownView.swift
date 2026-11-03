import Foundation
import SwiftUI

/// 用 Foundation 原生的 Markdown 解析（`AttributedString(markdown:)` 的 `.full` 语法）得到块结构，
/// 再映射为 SwiftUI 视图。不自行实现 Markdown 解析；只负责把标题、列表、引用、代码块排版出来。
/// HTML 注释（例如系统区块标记、来源标注）在渲染时不显示。
public struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    public init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct MarkdownBlock: Identifiable, Equatable {
    public enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case listItem(marker: String, depth: Int)
        case quote
        case code
        case divider
    }

    public let id: Int
    public let kind: Kind
    public let text: AttributedString

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        var current: (identity: Int, kind: Kind, text: AttributedString)?

        func flush() {
            guard let c = current else { return }
            let trimmed = String(c.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || c.kind == .divider {
                blocks.append(MarkdownBlock(id: blocks.count, kind: c.kind, text: c.text))
            }
            current = nil
        }

        for run in attributed.runs {
            // 没有块信息的片段是 HTML（注释、区块标记），不显示。
            guard let intent = run.presentationIntent, let innermost = intent.components.first else { continue }
            if current?.identity != innermost.identity {
                flush()
                current = (innermost.identity, kind(of: intent), AttributedString())
            }
            current?.text.append(attributed[run.range])
        }
        flush()
        return blocks
    }

    private static func kind(of intent: PresentationIntent) -> Kind {
        var depth = 0
        var marker: String?
        var ordered = false
        var quote = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .heading(level)
            case .codeBlock:
                return .code
            case .thematicBreak:
                return .divider
            case .listItem(let ordinal):
                depth += 1
                if marker == nil { marker = "\(ordinal)" }
            case .orderedList:
                if depth == 1 && marker != nil { ordered = true }
            case .blockQuote:
                quote = true
            default:
                break
            }
        }
        if let marker, depth > 0 {
            return .listItem(marker: ordered ? "\(marker)." : "•", depth: depth)
        }
        return quote ? .quote : .paragraph
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph:
            Text(block.text)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                Text(block.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 18)
        case .quote:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 3)
                Text(block.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code:
            Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
        }
    }
}
