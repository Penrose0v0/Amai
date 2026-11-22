import AmaiCore
import Foundation
import Testing
@testable import AmaiAssistant

/// 每轮发给助手模型（可能是云端模型）的屏幕上下文中的凭据。
///
/// 回归：选中文字与窗口标题经辅助功能读取，不经过 OCR 路径的脱敏，曾原样发给模型；
/// 打开聊天时还会在读不到选区时经菜单"拷贝"一次（`focusForChatOpening`），用户不一定意识到选区会被带上。
/// 现在 `ContextBuilder.contextBlock` 对所有来自屏幕的文字脱敏。
@Suite("Assistant context privacy")
struct AssistantPrivacyTests {
    private let key = "sk-ant-api03-abcdefghijklmnopqrstuv"

    private func context(selection: String? = nil, title: String? = nil, recentTitle: String? = nil) -> ContextBuilder.LiveContext {
        var context = ContextBuilder.LiveContext(time: Date(timeIntervalSince1970: 1_792_378_800))
        context.focus = FocusSnapshot(appName: "Terminal", bundleId: "com.apple.Terminal", pid: 1, accessibilityGranted: true, capturedAt: context.time)
        context.focus?.selectedText = selection
        context.focus?.windowTitle = title
        if let recentTitle {
            context.recent = [RecentTextState(
                firstSeen: context.time, lastSeen: context.time, appName: "Safari", windowTitle: recentTitle,
                text: "page text", source: .ocr
            )]
        }
        return context
    }

    @Test("ordinary selections and titles are passed through unchanged")
    func ordinaryContext() {
        let block = ContextBuilder(language: "Chinese", timeZone: TimeZone(identifier: "UTC")!)
            .contextBlock(context(selection: "func captureFrame()", title: "ScreenFrameSource.swift — Amai"))
        #expect(block.contains("func captureFrame()") && block.contains("ScreenFrameSource.swift — Amai"))
    }

    @Test("credentials in the selected text are redacted before reaching the model")
    func selectionRedacted() {
        let block = ContextBuilder(language: "Chinese", timeZone: TimeZone(identifier: "UTC")!)
            .contextBlock(context(selection: "export ANTHROPIC_API_KEY=\(key)"))
        #expect(!block.contains(key), "\(block)")
    }

    @Test("credentials in window titles are redacted before reaching the model")
    func titlesRedacted() {
        let title = "dashboard?token=\(key) — Safari"
        let block = ContextBuilder(language: "Chinese", timeZone: TimeZone(identifier: "UTC")!)
            .contextBlock(context(title: title, recentTitle: title))
        #expect(!block.contains(key), "\(block)")
    }
}
