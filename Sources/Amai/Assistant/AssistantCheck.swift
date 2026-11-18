import AmaiAssistant
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import AppKit
import Foundation
import enum AmaiCore.LiveContextError
import struct AmaiCore.FocusSnapshot
import enum AmaiCore.ScreenScope
import struct AmaiCore.ChatRequest

/// 开发用的助手端到端检查（与 `--inference-check` 同一类：隔离预览模式下运行，不影响正在运行的 Amai）。
///
///   Amai --memory-preview <目录> --assistant-check <输出目录> [--assistant-model <标签>]
///
/// 用预览目录里的合成记忆和一个本地模型，走真实的装配路径（AssistantController → AssistantSession → MLX）：
/// 记忆问答（后端检索与来源，不经过工具调用）、追问（KV cache 复用）、快速操作，以及真实的交互式屏幕读取。
/// 同一个问题分别以"直接提交"和"面板唤出时提前准备后提交"两种方式各问一次，记录各阶段耗时。
/// 结果写到 `assistant.json`，并截下聊天面板与快速操作面板。屏幕读取只记录尺寸与耗时，不保存截图和文字。
@MainActor
enum AssistantCheck {
    static func run(model: AppModel, output: URL, modelTag: String?) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tag = modelTag ?? LocalInferenceBackend.defaultModelTag
        var result: [String: Any] = ["model": tag, "installed": LocalInferenceBackend.isInstalled(tag: tag)]
        var checks: [String: Bool] = [:]

        // 独立的实时读取器：与正式运行时相同的截图源、OCR、辅助功能读取与默认排除名单，但没有后台采集。
        let target = TargetAppTracker()
        target.start()
        let live = LiveContextReader(dependencies: .init(
            screens: ScreenCaptureKitSource(), windows: ScreenCaptureKitSource(), target: target,
            secureInput: SystemSecureInputDetector(), policy: ExclusionListPolicy(),
            ocr: VisionTextRecognizer(), focus: AccessibilityReader(),
            alwaysExcludedBundleIds: Bundle.main.bundleIdentifier.map { [$0] } ?? []
        ))

        var configuration = AssistantConfiguration.default
        configuration.agent = .local(tag)
        configuration.memoryCategories = MemoryCategory.allCases
        let controller = AssistantController(
            configuration: configuration,
            environment: .init(
                live: live, memoryRoot: model.memoryRoot, memoryIndex: model.memoryIndex,
                embedder: model.memoryEmbedder, keychain: model.keychain, chatGPT: model.chatGPT,
                claudeWorkdir: output.appendingPathComponent("claude"),
                storeURL: output.appendingPathComponent("assistant.sqlite"),
                language: { model.memoryLanguage }, openSource: { _ in }, openSettings: {}
            )
        )
        result["ready"] = controller.isReady
        result["setupMessage"] = controller.setupMessage ?? ""

        // 1. 实时屏幕读取。
        var screen: [String: Any] = [:]
        let focus = await live.focus()
        screen["accessibilityGranted"] = focus.accessibilityGranted
        screen["hasApp"] = focus.appName != nil
        screen["hasWindowTitle"] = focus.windowTitle != nil
        for (name, scope) in [("desktop", ScreenScope.desktop), ("window", ScreenScope.focusedWindow)] {
            let started = Date()
            do {
                let image = try await live.screen(scope, maxAge: 2, maxHeight: 1080)
                screen[name] = ["bytes": image.jpeg.count, "scope": image.scope.rawValue, "ms": Int(Date().timeIntervalSince(started) * 1000)]
            } catch {
                screen[name] = ["error": String(describing: error)]
            }
        }
        let ocrStarted = Date()
        if let text = try? await live.screenText(.focusedWindow, maxAge: 5) {
            screen["ocr"] = ["characters": text.count, "ms": Int(Date().timeIntervalSince(ocrStarted) * 1000)]
        }
        result["screen"] = screen

        // 2. 记忆索引：混合检索需要的向量（合成记忆，量很小）。
        var memory: [String: Any] = ["embedderInstalled": model.memoryEmbedder.isAvailable]
        if let index = model.memoryIndex {
            let started = Date()
            _ = try? await index.refresh()
            memory["embedded"] = (try? await index.embedPending(using: model.memoryEmbedder)) ?? 0
            memory["indexMs"] = Int(Date().timeIntervalSince(started) * 1000)
        }
        result["memory"] = memory

        // 3. 记忆问答。
        let chat = controller.chat
        let local = MLXChatModel(modelTag: tag)
        func ask(_ text: String) async -> [String: Any] {
            let started = Date()
            chat.input = text
            chat.send()
            while chat.isStreaming { try? await Task.sleep(for: .milliseconds(50)) }
            let reply = chat.messages.last
            let timings = await controller.session?.lastTimings
            let stats = await local.prefixStats.chat
            return [
                "question": text,
                "answer": reply?.content ?? "",
                "sources": (reply?.sources ?? []).map { "\($0.file)#\($0.section ?? "")#\($0.date ?? "")" },
                "error": chat.errorBanner ?? "",
                "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                "preparationMs": timings?.preparationMs ?? -1,
                "memoryMs": timings?.memoryMs ?? -1,
                "firstTextMs": timings?.firstTextMs ?? -1,
                "usedPreparedContext": timings?.usedPreparedContext ?? false,
                "promptTokens": stats.promptTokens,
                "cachedPromptTokens": stats.cachedTokens,
                "modelPrefillMs": stats.prefillMs,
            ]
        }
        func answer(_ entry: [String: Any]) -> String { entry["answer"] as? String ?? "" }
        if controller.isReady {
            // 先把模型加载好，两种提交方式都不含加载时间（加载耗时单独记录）。
            let loadStarted = Date()
            await local.prepare(ChatRequest(system: "warm up", messages: []))
            result["modelLoadMs"] = Int(Date().timeIntervalSince(loadStarted) * 1000)
            let question = "我在 2026-11-06 那天主要做了什么？"

            // 3a. 直接提交：屏幕读取、OCR、记忆检索、整段提示词的处理都发生在提交之后。
            // 绕过界面直接调用会话：界面在新建对话时会自动开始准备，这里要的正是"没有准备"的基线。
            var cold: [String: Any] = ["question": question]
            if let session = controller.session {
                await live.forget()
                await session.reset()
                var text = ""
                do {
                    for try await event in session.send(question) {
                        if case .finished(let answer, _) = event { text = answer }
                    }
                } catch {
                    cold["error"] = String(describing: type(of: error))
                }
                let timings = await session.lastTimings
                let stats = await local.prefixStats.chat
                cold["answer"] = text
                cold["preparationMs"] = timings.preparationMs
                cold["memoryMs"] = timings.memoryMs
                cold["firstTextMs"] = timings.firstTextMs ?? -1
                cold["usedPreparedContext"] = timings.usedPreparedContext
                cold["promptTokens"] = stats.promptTokens
                cold["cachedPromptTokens"] = stats.cachedTokens
                cold["modelPrefillMs"] = stats.prefillMs
            }

            // 3b. 面板唤出时提前准备（用户这时还在打字），然后提交同一个问题。
            await live.forget()
            chat.newSession()
            try? await Task.sleep(for: .milliseconds(300))
            let prepareStarted = Date()
            _ = await controller.prepareSession()
            let prepareMs = Int(Date().timeIntervalSince(prepareStarted) * 1000)
            let prefilled = await local.prefixStats.prefill
            let first = await ask(question)
            // 上一轮结束后界面会自动为下一轮做准备；检查里等它做完，测到的是稳定值。
            _ = await controller.prepareSession()
            let second = await ask("那天做了什么决定？")
            _ = await controller.prepareSession()
            // 措辞与记忆里的写法不同（记忆里写的是"放弃 CloudKit，改用自建同步服务，因为需要支持 Android"）。
            let semantic = await ask("为什么不用苹果的云服务来同步数据？")

            result["conversation"] = [first, second, semantic]
            result["coldSubmit"] = cold
            result["prepare"] = [
                "ms": prepareMs, "prefilledTokens": prefilled.promptTokens, "modelPrefillMs": prefilled.prefillMs,
            ]
            // 发给模型的消息只有 user / assistant 两种：没有工具调用，也没有工具结果。
            if let session = controller.session {
                let transcript = await session.transcript
                result["transcript"] = transcript.map { "\($0.role.rawValue)(\($0.text.count) chars)" }
                checks["noToolCalls"] = transcript.allSatisfy { $0.role != .tool && $0.toolCalls.isEmpty }
            }
            checks["answersFromMemory"] = !(first["sources"] as? [String] ?? []).isEmpty
                && ["Lumen", "同步", "官网"].contains { answer(first).contains($0) }
            checks["sameAnswerQualityCold"] = ["Lumen", "同步", "官网"].contains { answer(cold).contains($0) }
            checks["followUpAnswered"] = ["CloudKit", "同步服务", "官网"].contains { answer(second).contains($0) }
            checks["semanticRecall"] = ["Android", "安卓"].contains { answer(semantic).contains($0) }
            checks["preparedContextUsed"] = first["usedPreparedContext"] as? Bool ?? false
            checks["prefillHit"] = (first["cachedPromptTokens"] as? Int ?? 0) >= prefilled.promptTokens && prefilled.promptTokens > 0
            checks["preparedIsFaster"] = (first["firstTextMs"] as? Int ?? .max) < (cold["firstTextMs"] as? Int ?? 0)
            checks["kvCacheReused"] = (second["cachedPromptTokens"] as? Int ?? 0) > (first["promptTokens"] as? Int ?? .max)
            checks["historySaved"] = ((try? controller.store?.messages(in: chat.currentSessionId))?.count ?? 0) == 6

            controller.showChat()
            await shot(controller, title: "chat", output: output)

            // 4. 快速操作：翻译与润色（一次性请求，不进入对话历史）。
            let selection = "The quick brown fox jumps over the lazy dog."
            let quick = QuickActionModel(
                focus: FocusSnapshot(appName: "TextEdit", selectedText: selection, selectionIsEditable: true, accessibilityGranted: true),
                assistant: controller
            )
            var quickResults: [String: String] = [:]
            for action in [QuickAction.translate, .polish] {
                quick.run(action)
                while quick.running != nil { try? await Task.sleep(for: .milliseconds(100)) }
                quickResults[action.rawValue] = quick.error ?? quick.result
            }
            result["quickActions"] = quickResults
            controller.toggleChat()
            try? await Task.sleep(for: .milliseconds(400))
            let panel = QuickActionPanelController()
            panel.show(quick)
            await shot(controller, title: "quick", output: output)
            panel.close()
            checks["translated"] = (quickResults["translate"] ?? "").unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            checks["polished"] = !(quickResults["polish"] ?? "").isEmpty && quick.canReplace
            checks["quickActionsLeaveHistoryAlone"] = chat.messages.count == 6
            // 快速操作之后接着对话：对话的缓存不应被一次性请求顶掉。
            let after = await ask("谢谢。用一句话总结一下。")
            checks["cacheSurvivesQuickActions"] = (after["cachedPromptTokens"] as? Int ?? 0) > (semantic["promptTokens"] as? Int ?? .max)
        }

        result["checks"] = checks
        result["ok"] = controller.isReady && checks.values.allSatisfy { $0 }
        await MLXModelProvider(modelTag: tag).unload(reason: "assistant check finished")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("assistant.json"))
        }
        NSApp.terminate(nil)
    }

    /// 截下聊天面板（只截本应用自己的窗口）。
    private static func shot(_ controller: AssistantController, title: String, output: URL) async {
        try? await Task.sleep(for: .milliseconds(1200))
        guard let window = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width > 300 }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent("\(title).png").path]
        try? process.run()
        process.waitUntilExit()
    }
}
