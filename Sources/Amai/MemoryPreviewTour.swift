import AmaiExtraction
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

        // 搜索词需与样本语言一致（英文样本用 `--memory-preview-query sync`）。
        let args = CommandLine.arguments
        browser.query = args.firstIndex(of: "--memory-preview-query").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "同步"
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

        // 设置窗口的本地模型页。
        model.settingsRequests += 1
        try? await Task.sleep(for: .milliseconds(1200))
        // SwiftUI 的设置窗口没有 identifier：取主窗口之外的可见普通窗口。
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") != true && $0.frame.width > 300 }) {
            let path = output.appendingPathComponent("14-local-models.png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(settings.windowNumber)", path]
            try? p.run()
            p.waitUntilExit()
            log.append("14-local-models：\(p.terminationStatus == 0 ? "ok" : "截图失败 \(p.terminationStatus)")")
        } else {
            log.append("14-local-models：找不到设置窗口 \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" })")
        }

        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// 发布前检查本地推理（`--memory-preview <目录> --inference-check <输出目录> [--inference-model <标签>]`）：
    /// 在本进程中新建一个本地模型实例，依次做纯文本生成与三项视觉对照，结果写入 inference.json 后退出。
    /// 视觉对照：读出合成图片上的文字；说出纯色图片的颜色；同一问题不带图时答不出图中文字。
    /// 三项都满足才说明图片真正进入了模型（只靠文字的模型会在前两项失败）。
    /// 只读取 Hugging Face 缓存中已安装的权重；不读写真实记忆、配置与原始数据，不启动采集。
    /// 加上 `--inference-download` 时，未安装的模型先用设置中的同一个下载器下载到 Hugging Face 缓存。
    static func runInferenceCheck(output: URL, modelTag: String?, download: Bool = false) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tag = modelTag ?? LocalInferenceBackend.defaultModelTag
        let expected = "AMAI 7428"  // 不用 0：等宽字体的斜线零会被如实读成 Ø
        var result: [String: Any] = ["model": tag, "installed": LocalInferenceBackend.isInstalled(tag: tag)]
        if download, !LocalInferenceBackend.isInstalled(tag: tag) {
            do {
                for try await _ in LocalModelDownloader.download(tag: tag) {}
                result["downloaded"] = true
            } catch {
                result["downloadError"] = String(describing: error)
            }
        }
        let provider = MLXModelProvider(modelTag: tag)
        func ask(_ system: String, _ prompt: String, _ images: [Data] = [], maxTokens: Int = 16) async throws -> ModelResponse {
            try await provider.generate(ModelRequest(
                cacheable: system, dynamic: prompt, images: images, maxTokens: maxTokens, temperature: 0
            ))
        }
        do {
            let text = try await ask("You are a terse assistant.", "Reply with exactly one word: ready", maxTokens: 8)
            let readText = "What text is written in this image? Reply with the text only."
            let image = try await ask("You read text from screenshots.", readText, [Self.syntheticImage(expected)])
            let color = try await ask(
                "You describe images.", "What is the background color of this image? Reply with one word.",
                [Self.syntheticImage("", background: .red, size: NSSize(width: 448, height: 448))], maxTokens: 8
            )
            let blind = try await ask("You read text from screenshots.", readText)
            let checks: [String: Bool] = [
                "text": !text.text.isEmpty,
                "readsImageText": image.text.uppercased().contains(expected),
                "seesColor": color.text.lowercased().contains("red"),
                "noImageControl": !blind.text.uppercased().contains(expected),
            ]
            result["outputs"] = [
                "text": text.text, "image": image.text, "color": color.text, "noImage": blind.text,
            ]
            result["latencyMs"] = [
                "textIncludingLoad": text.latencyMs, "image": image.latencyMs, "color": color.latencyMs, "noImage": blind.latencyMs,
            ]
            result["checks"] = checks
            result["ok"] = checks.values.allSatisfy { $0 }
        } catch {
            result["error"] = String(describing: error)
            result["ok"] = false
        }
        await provider.unload(reason: "inference check finished")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("inference.json"))
        }
        NSApp.terminate(nil)
    }

    /// 白底黑字的合成"截图"，JPEG 编码（与抽取流水线传给模型的格式相同）。
    private static func syntheticImage(
        _ text: String, background: NSColor = .white, size: NSSize = NSSize(width: 640, height: 240)
    ) -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return Data() }
        return jpeg
    }

    /// 首次使用引导的每一步（`--memory-preview <目录> --onboarding-tour <输出目录>`）。预览模式中授权、下载与完成都不生效。
    static func runOnboarding(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        try? await Task.sleep(for: .seconds(2))
        for step in OnboardingState.Step.allCases {
            model.onboarding.step = step
            try? await Task.sleep(for: .milliseconds(900))
            guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("onboarding") == true && $0.isVisible }) else {
                log.append("\(step)：找不到引导窗口 \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" })")
                continue
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(w.windowNumber)", output.appendingPathComponent("\(step.rawValue)-\(step).png").path]
            try? p.run()
            p.waitUntilExit()
            log.append("\(step)：\(p.terminationStatus == 0 ? "ok" : "截图失败 \(p.terminationStatus)") \(Int(w.frame.width))×\(Int(w.frame.height))")
        }
        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("tour.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
