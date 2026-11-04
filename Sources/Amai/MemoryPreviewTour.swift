import AmaiMemory
import AmaiMemoryUI
import AppKit
import Foundation

/// 开发用：在隔离预览模式（`--memory-preview <目录> --memory-preview-tour <输出目录>`）中依次切换记忆窗口的状态并截图，
/// 用于在真机上检查完整窗口。只截取本应用自己的记忆窗口，只读写预览目录中的合成数据。
@MainActor
enum MemoryPreviewTour {
    static func run(model: AppModel, output: URL) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        let browser = model.memoryBrowser

        func window() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true && $0.isVisible }
        }
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(900))
            guard let w = window() else { log.append("\(name)：找不到记忆窗口"); return }
            let path = output.appendingPathComponent("\(name).png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
            try? p.run()
            p.waitUntilExit()
            log.append("\(name)：\(p.terminationStatus == 0 ? "ok" : "截图失败 \(p.terminationStatus)") \(Int(w.frame.width))×\(Int(w.frame.height))")
        }
        func resize(_ w: CGFloat, _ h: CGFloat) {
            guard let win = window() else { return }
            win.setFrame(NSRect(x: 80, y: 80, width: w, height: h), display: true)
        }

        try? await Task.sleep(for: .seconds(2))
        NSApp.activate(ignoringOtherApps: true)
        window()?.makeKeyAndOrderFront(nil)
        resize(1080, 720)
        log.append("初始页面：\(String(describing: browser.selection))")
        await shot("00-initial")

        for (i, c) in MemoryCategory.documents.enumerated() {
            browser.selection = .category(c)
            await shot("0\(i + 1)-\(c.rawValue)")
        }

        browser.selection = .category(.general)
        browser.historyExpanded = true
        await shot("06-general-history")
        browser.historyExpanded = false
        browser.selection = .category(.work)

        if let first = model.memoryLibrary.document(.work)?.systemItems.first, let day = first.sources.first {
            browser.presentedSource = "\(first.text)|\(day)"
            await shot("07-source-popover")
            browser.presentedSource = nil
        }

        browser.query = "同步"
        await browser.search(model.memoryBrowserEnvironment)
        await shot("08-search")
        browser.clearSearch()

        browser.selection = .category(.general)
        resize(760, 500)
        await shot("09-min-size")
        resize(1500, 950)
        await shot("10-large")
        resize(1080, 720)

        // 外部修改：在编辑器里给 health.md 加一行，窗口应在几秒内自动刷新。
        browser.selection = .category(.health)
        try? await Task.sleep(for: .seconds(1))
        let health = model.memoryRoot.appendingPathComponent("health.md")
        if var text = try? String(contentsOf: health, encoding: .utf8) {
            text = text.replacingOccurrences(of: "# Health\n", with: "# Health\n\n外部编辑器刚加的一行。\n")
            try? text.write(to: health, atomically: true, encoding: .utf8)
        }
        try? await Task.sleep(for: .seconds(3))
        await shot("11-external-edit")

        // 时间线与每日总结：跳到样本中最近的一天。
        let daily = model.memoryRoot.appendingPathComponent("daily", isDirectory: true)
        let latest = ((try? fm.contentsOfDirectory(atPath: daily.path)) ?? []).filter { $0.hasSuffix(".md") }.max()
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        if let latest, let day = parser.date(from: String(latest.dropLast(3))) {
            browser.day = day
            browser.selection = .timeline
            await shot("12-timeline")
            browser.selection = .dailySummary
            await shot("13-daily-summary")
        } else {
            log.append("timeline：样本中没有每日记录")
        }

        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
