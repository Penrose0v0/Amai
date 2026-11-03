import AmaiCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AmaiMemory
@testable import AmaiMemoryUI

@Suite("MarkdownBlock")
struct MarkdownBlockTests {
    @Test("native parsing yields headings, nested and ordered lists, quotes; HTML comments are hidden")
    func blocks() {
        let blocks = MarkdownBlock.parse("""
        # 标题

        正文 **加粗**。

        ## 小节
        - 一
          - 嵌套
        1. 有序

        <!-- amai:memory:begin · x -->
        > 引用
        """)
        #expect(blocks.map(\.kind) == [
            .heading(1), .paragraph, .heading(2),
            .listItem(marker: "•", depth: 1), .listItem(marker: "•", depth: 2), .listItem(marker: "1.", depth: 1),
            .quote,
        ])
        #expect(!blocks.contains { String($0.text.characters).contains("amai:memory") })
    }
}

/// 用合成记忆渲染记忆窗口，检查能正常排版。设置 `AMAI_UI_SNAPSHOT_DIR` 时把文档页截图写到该目录，供人工查看。
@Suite("MemoryBrowser rendering")
@MainActor
struct MemoryBrowserRenderingTests {
    static func fixture() throws -> URL {
        let root = try tempDir()
        try """
        # Work

        这里是我自己写的项目笔记，**Amai 不会改动**。

        - 每周五整理一次进度
        - 参考 [设计文档](https://example.com)

        ## Amai 整理的记忆

        <!-- amai:memory:begin · x -->
        ### Lumen <!-- project:p-111111 -->
        - 〔决策〕放弃 CloudKit，改用自建同步服务 <!-- src:2026-10-06 kind:stated -->
        - 在开发离线同步的冲突合并 <!-- src:2026-10-05 kind:inferred -->
        ### Orbit <!-- project:p-333333 aka:Atlas -->
        - 使用 Xcode 约三小时 <!-- src:2026-11-09 kind:observed -->
        - 搭建数据标注工具 <!-- src:2026-10-25 -->
        ### 变更记录
        - 2026-10-25 撤下：「后端原型使用 Python 编写」（已迁移到 Go） <!-- src:2026-10-25 kind:stated -->
        <!-- amai:memory:end -->

        ## 迁移自 work/projects/old.md

        旧文件里的手写内容。
        """.write(to: root.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
        return root
    }

    static func environment(_ root: URL) -> MemoryBrowserEnvironment {
        MemoryBrowserEnvironment(
            library: MemoryLibrary(root: root, index: nil, timeZone: utc),
            search: { _ in [] }, openFile: { _ in }, reveal: { _ in }
        )
    }

    /// 整窗渲染只用来检查视图能构建、布局不崩溃。离屏抓图画不出 SwiftUI 文字，所以不导出截图。
    func layout(_ view: some View, size: CGSize) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test("a category document renders user text, grouped system entries and history")
    func documentPage() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = Self.environment(root)
        let document = try #require(env.library.document(.work))
        #expect(document.systemItems.count == 5)
        let renderer = ImageRenderer(content: MemoryDocumentPage(env: env, document: document).frame(width: 760).background(.white))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.height > 300)
        if let dir = ProcessInfo.processInfo.environment["AMAI_UI_SNAPSHOT_DIR"],
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("work-document.png"))
        }
    }

    @Test("the browser window renders with the sidebar and an empty category")
    func window() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = Self.environment(root)
        layout(MemoryBrowserView(env: env, initial: .work), size: CGSize(width: 1000, height: 680))
        layout(MemoryBrowserView(env: env, initial: .health), size: CGSize(width: 1000, height: 680))
    }
}

@Suite("Search excerpt")
struct SearchExcerptTests {
    @Test("Markdown markers are removed from search excerpts")
    func plain() {
        #expect(SearchResultsView.plain("…Amai 不会改动**。 - 每周五整理 - 参考 [设计文档](https://example.com) - 同步协议草案")
            == "…Amai 不会改动。 · 每周五整理 · 参考 设计文档 · 同步协议草案")
        #expect(SearchResultsView.plain("### Lumen - 〔决策〕放弃 CloudKit") == "Lumen · 〔决策〕放弃 CloudKit")
    }
}
