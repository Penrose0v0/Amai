// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import struct AmaiCore.ActivitySegment
import enum AmaiCore.AmaiLog
import struct AmaiCore.AmaiPaths
import struct AmaiCore.Evidence
import enum AmaiCore.FrameAvailability
import protocol AmaiCore.PerceptionReading
import struct AmaiCore.TimeRange
import AmaiCloud
import AmaiExtraction
import AmaiMemory
import AmaiPerception
import AppKit
import Foundation
import Observation

/// 菜单栏与检查器的状态源。只调用各层的公开接口。
@MainActor
@Observable
final class AppModel {
    private(set) var status: PerceptionStatus?
    private(set) var extractionStatus: ExtractionStatus?
    private(set) var startupError: String?
    private(set) var configWarning: String?
    private(set) var modelInstalled = true
    private(set) var memoryStatus: MemorySync.Status?
    private(set) var consolidationStatus: Consolidator.Status?
    /// 记忆目录中最近一次文件修改的时间（菜单显示"记忆更新于…"）。
    private(set) var lastMemoryUpdate: Date?
    private var lastMemoryScan = Date.distantPast
    /// 当前整理模型配置。修改通过 `applyConsolidationModel` 进行。
    private(set) var consolidationModel: ConsolidationModelConfiguration
    let keychain = KeychainStore()
    /// ChatGPT 订阅会话（SIWC）。令牌在钥匙串中，由会话自己管理刷新。
    let chatGPT: ChatGPTSession
    private(set) var chatGPTStatus: ChatGPTSession.Status?
    private let claudeWorkdir: URL
    private var configuration: AppConfiguration
    private let localModel: MLXModelProvider?
    let modelTag: String
    let memoryRoot: URL

    private let paths: AmaiPaths?
    private let coordinator: PerceptionCoordinator?
    let reader: (any PerceptionReading)?
    let extractionStore: ExtractionStore?
    private let pipeline: ExtractionPipeline?
    private let memorySync: MemorySync?
    private let consolidator: Consolidator?
    let memoryIndex: MemoryIndex?
    private var pollTask: Task<Void, Never>?

    init() {
        var paths: AmaiPaths?
        var coordinator: PerceptionCoordinator?
        var reader: SpoolReader?
        var store: ExtractionStore?
        var pipeline: ExtractionPipeline?
        var memorySync: MemorySync?
        var memoryIndex: MemoryIndex?
        var consolidator: Consolidator?
        var localModel: MLXModelProvider?
        let keychain = KeychainStore()
        // 浏览器授权：用系统默认浏览器打开 OpenAI 授权页。
        let chatGPT = ChatGPTSession(store: keychain, openURL: { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        })
        var claudeWorkdir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-claude-cli")
        var configWarning: String?
        var startupError: String?
        var config = AppConfiguration.default
        do {
            let resolved = try AmaiPaths.standard()
            try resolved.ensureDirectories()
            let loaded = ConfigStore.load(from: resolved.config)
            config = loaded.configuration
            configWarning = loaded.error
            paths = resolved
            claudeWorkdir = resolved.root.appendingPathComponent("claude-cli", isDirectory: true)

            let perception = try PerceptionCoordinator(paths: resolved, configuration: config.perception)
            coordinator = perception
            let spoolReader = SpoolReader(spool: perception.spool)
            reader = spoolReader
            let extractedStore = try ExtractionStore(root: resolved.extracted)
            store = extractedStore
            // 抽取与记忆整理共用一个本地模型实例，避免重复加载权重。
            let model = MLXModelProvider(modelTag: config.extraction.modelTag)
            localModel = model
            // 电池低于 40%、低电量模式或过热时推迟推理，插电后追赶。
            let heavyWorkAllowed: @Sendable () -> Bool = { [perception] in
                switch perception.currentPowerProfile {
                case .performance, .balanced: true
                case .saver, .paused: false
                }
            }
            let built = ExtractionPipeline(dependencies: .init(
                reader: spoolReader,
                model: model,
                ocr: VisionTextRecognizer(),
                store: extractedStore,
                shouldRun: heavyWorkAllowed
            ))
            pipeline = built

            let memoryStore = try MemoryStore(root: config.memory.rootURL)
            let index = MemoryIndex(
                root: config.memory.rootURL,
                database: try MemoryIndexDatabase(path: resolved.index.appendingPathComponent("memory.sqlite").path)
            )
            memoryIndex = index
            memorySync = MemorySync(
                source: ExtractionSegmentSource(store: extractedStore),
                store: memoryStore,
                index: index,
                stateURL: resolved.index.appendingPathComponent("memory-sync.json")
            )
            consolidator = Consolidator(
                store: memoryStore,
                source: ExtractionSegmentSource(store: extractedStore),
                model: ConsolidationModelFactory.make(config.consolidationModel, context: ConsolidationModelContext(
                    local: model, keychain: keychain, chatGPT: chatGPT,
                    claudeWorkdir: resolved.root.appendingPathComponent("claude-cli", isDirectory: true)
                )),
                snapshots: SnapshotStore(root: resolved.root.appendingPathComponent("snapshots", isDirectory: true)),
                stateURL: resolved.index.appendingPathComponent("consolidation.json"),
                shouldRun: heavyWorkAllowed
            )
        } catch {
            startupError = "初始化失败：\(error)"
            AmaiLog.logger("app").error("startup failed: \(String(describing: error), privacy: .public)")
        }
        self.paths = paths
        self.coordinator = coordinator
        self.reader = reader
        self.extractionStore = store
        self.pipeline = pipeline
        self.memorySync = memorySync
        self.memoryIndex = memoryIndex
        self.consolidator = consolidator
        self.localModel = localModel
        self.chatGPT = chatGPT
        self.claudeWorkdir = claudeWorkdir
        self.configuration = config
        self.consolidationModel = config.consolidationModel
        self.memoryRoot = config.memory.rootURL
        self.configWarning = configWarning
        self.startupError = startupError
        self.modelTag = config.extraction.modelTag
        self.modelInstalled = LocalInferenceBackend.isInstalled(tag: config.extraction.modelTag)

        if let pipeline {
            let extraction = config.extraction
            Task {
                await pipeline.apply(extraction)
                await pipeline.start()
            }
        }
        if let memorySync {
            Task { await memorySync.start() }
        }
        if let consolidator {
            Task { await consolidator.start() }
        }
        // 先恢复异常退出残留的分段，再恢复采集，避免新分段被误当成残留处理。
        if let coordinator {
            Task {
                await coordinator.recoverInterruptedSegments()
                self.restoreCaptureState()
            }
        }
        startPolling()

        // 开发用启动参数：open .build/Amai.app --args --consolidate-today [--update-summary]
        let args = CommandLine.arguments
        if args.contains("--consolidate-today") || args.contains("--update-summary") {
            Task { [weak self] in
                guard let self, let consolidator = self.consolidator, let memorySync = self.memorySync else { return }
                await memorySync.syncOnce()
                if args.contains("--consolidate-today") { _ = try? await consolidator.consolidateDay(Date()) }
                if args.contains("--update-summary") { _ = try? await consolidator.updateSummary() }
                await memorySync.syncOnce()
                await self.refresh()
            }
        }
    }

    // MARK: - Perception actions

    /// 用户最后一次选择的采集状态。退出应用不改变它，下次启动时恢复：
    /// 采集始终由用户显式开启，应用只是记住这个选择。
    private enum CaptureIntent: String {
        case running, paused
    }

    private static let captureIntentKey = "amai.captureIntent"

    private var captureIntent: CaptureIntent? {
        get { UserDefaults.standard.string(forKey: Self.captureIntentKey).flatMap(CaptureIntent.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Self.captureIntentKey) }
    }

    private func restoreCaptureState() {
        guard let coordinator, let intent = captureIntent else { return }
        Task {
            await coordinator.start()
            if intent == .paused { await coordinator.pause() }
            await refresh()
        }
    }

    func start() {
        captureIntent = .running
        Task { await coordinator?.start(); await refresh() }
    }

    func pause() {
        captureIntent = .paused
        Task { await coordinator?.pause(); await refresh() }
    }

    func resume() {
        captureIntent = .running
        Task { await coordinator?.resume(); await refresh() }
    }

    /// 退出前先停止采集，让写入中的视频分段正常收尾。
    func quit() {
        Task {
            await consolidator?.stop()
            await memorySync?.stop()
            await pipeline?.stop()
            await coordinator?.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    /// 重新启动 Amai：先像退出时一样收尾，再由一个短命的 shell 在本进程退出后重新打开 App。
    /// macOS 的屏幕录制授权只在 App 重新启动后生效。
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        Task {
            await consolidator?.stop()
            await memorySync?.stop()
            await pipeline?.stop()
            await coordinator?.stop()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundlePath]
            try? process.run()
            NSApplication.shared.terminate(nil)
        }
    }

    func requestScreenRecording() {
        if !ScreenRecordingPermission.request() {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    func openSystemSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }

    func revealRawFolder() {
        guard let paths else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.raw])
    }

    func revealConfig() {
        guard let paths else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.config])
    }

    func openMemoryFolder() {
        try? FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(memoryRoot)
    }

    /// 手动整理今天：生成今天的日终摘要并更新 work/ 专题（不影响凌晨的正式整理）。
    func consolidateToday() {
        guard let consolidator, let memorySync else { return }
        Task {
            await memorySync.syncOnce()
            _ = try? await consolidator.consolidateDay(Date())
            await memorySync.syncOnce()
            await refresh()
        }
    }

    func updateSummaryNow() {
        guard let consolidator, let memorySync else { return }
        Task {
            _ = try? await consolidator.updateSummary()
            await memorySync.syncOnce()
            await refresh()
        }
    }

    // MARK: - Consolidation model

    var consolidationModelLabel: String {
        ConsolidationModelFactory.label(consolidationModel, localIdentifier: localModel?.identifier ?? "本地模型")
    }

    private var modelContext: ConsolidationModelContext? {
        guard let localModel else { return nil }
        return ConsolidationModelContext(local: localModel, keychain: keychain, chatGPT: chatGPT, claudeWorkdir: claudeWorkdir)
    }

    /// 保存整理模型配置并立即切换。返回错误说明（成功为 nil）。
    func applyConsolidationModel(_ new: ConsolidationModelConfiguration) async -> String? {
        guard let paths, let context = modelContext, let consolidator else { return "应用未正确初始化" }
        var updated = configuration
        updated.consolidationModel = new
        do {
            try ConfigStore.save(updated, to: paths.config)
        } catch {
            return "保存配置失败：\(error)"
        }
        configuration = updated
        consolidationModel = new
        await consolidator.setModel(ConsolidationModelFactory.make(new, context: context))
        AmaiLog.logger("app").info("consolidation model switched to \(new.mode.rawValue, privacy: .public)")
        return nil
    }

    /// 用一个极小的请求测试连接，不发送任何记忆内容。
    func testConnection(_ config: ConsolidationModelConfiguration, apiKey: String?) async -> String {
        guard let context = modelContext else { return "应用未正确初始化" }
        let client: any CloudTextClient
        if config.mode == .apiKey, let key = apiKey, !key.isEmpty {
            client = config.apiKeyClient(apiKey: key)
        } else {
            switch ConsolidationModelFactory.client(config, context: context) {
            case .success(let c): client = c
            case .failure(let error): return "连接失败：\(error.description)"
            }
        }
        do {
            let response = try await client.generate(CloudRequest(system: "Reply with the single word OK.", user: "ping", maxTokens: 16))
            return "连接成功：\(response.model)，用量 \(response.inputTokens) / \(response.outputTokens) token"
        } catch let error as CloudError {
            return "连接失败：\(error.description)"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - ChatGPT subscription (SIWC)

    func refreshChatGPTStatus() async {
        chatGPTStatus = await chatGPT.status
    }

    /// 浏览器登录。成功返回 nil，失败返回原因。
    func signInChatGPT() async -> String? {
        defer { Task { await refreshChatGPTStatus() } }
        do {
            try await chatGPT.signIn()
            return nil
        } catch let error as CloudError {
            return error.description
        } catch {
            return "登录失败：\(error.localizedDescription)"
        }
    }

    /// 退出登录。撤销未确认时返回提示。
    func signOutChatGPT() async -> String? {
        let revoked = await chatGPT.signOut()
        await refreshChatGPTStatus()
        if consolidationModel.mode == .chatgptPlan { _ = await applyConsolidationModel(consolidationModel) }
        return revoked ? nil : "未能确认撤销授权，请到 ChatGPT 设置中断开 Amai。本地令牌已清除。"
    }

    func chatGPTModels() async -> Result<[ChatGPTModel], CloudError> {
        do {
            return .success(try await chatGPT.listModels())
        } catch let error as CloudError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    func markChatGPTWelcomed() async {
        try? await chatGPT.markWelcomed()
        await refreshChatGPTStatus()
    }

    func openChatGPTUsage() {
        NSWorkspace.shared.open(chatGPTUsageURL)
    }

    let chatGPTUsageURL = SIWCConfiguration().manageUsageURL

    // MARK: - Claude subscription (Claude Code CLI)

    func claudeCodeStatus(configuredPath: String) async -> Result<ClaudeCodeStatus, CloudError> {
        guard let exe = ClaudeCodeLocator.locate(configured: configuredPath) else {
            return .failure(.toolNotFound(configuredPath.isEmpty ? "未在常见位置找到 claude" : configuredPath))
        }
        do {
            return .success(try await ClaudeCodeClient.status(executable: exe, workingDirectory: claudeWorkdir))
        } catch let error as CloudError {
            return .failure(error)
        } catch {
            return .failure(.local(error.localizedDescription))
        }
    }

    func syncMemoryNow() {
        guard let memorySync else { return }
        Task {
            await memorySync.syncOnce()
            await refresh()
        }
    }

    /// 删除时间段内的全部数据：原始截图与索引、抽取结果，以及 daily 中对应的时间线条目。
    /// 区块外用户手写的内容不受影响。
    func eraseData(from start: Date, to end: Date) async -> String {
        guard end > start else { return "结束时间必须晚于开始时间" }
        var notes: [String] = []
        do {
            if let coordinator {
                let files = try await coordinator.erase(from: start, to: end)
                notes.append("删除原始视频分段 \(files) 个")
            }
            let days = try await extractionStore?.deleteData(overlapping: TimeRange(start: start, end: end)) ?? []
            notes.append("影响 \(days.count) 天的抽取结果")
            if let memorySync {
                for day in days { try await memorySync.rewrite(day: day) }
                await memorySync.syncOnce()
            }
            return notes.joined(separator: "，")
        } catch {
            return "删除未完成：\(error)。" + notes.joined(separator: "，")
        }
    }

    // MARK: - Extraction actions

    /// 手动触发一轮抽取，忽略电源档位限制。
    func runExtractionNow() {
        guard let pipeline else { return }
        Task {
            _ = await pipeline.runOnce(force: true)
            await refresh()
        }
    }

    func segments(on day: Date) async -> [ActivitySegment] {
        await extractionStore?.segments(on: day) ?? []
    }

    func search(_ query: String, endingOn day: Date) async -> [ActivitySegment] {
        await extractionStore?.search(query, endingOn: day) ?? []
    }

    func observations(for segment: ActivitySegment) async -> [AmaiCoreObservation] {
        guard let store = extractionStore else { return [] }
        return await store.observations(ids: Set(segment.observations), on: segment.timeRange.start)
            .sorted { $0.timeRange.start < $1.timeRange.start }
    }

    func deleteSegment(_ segment: ActivitySegment) async {
        try? await extractionStore?.deleteSegment(id: segment.id, on: segment.timeRange.start)
        // 片段删除后立即重渲染当天的时间线区块。
        try? await memorySync?.rewrite(day: segment.timeRange.start)
    }

    func searchMemory(_ query: String) async -> [MemoryHit] {
        (try? await memoryIndex?.retrieve(query, limit: 20)) ?? []
    }

    func thumbnail(for evidence: Evidence, maxHeight: Int = 360) async -> NSImage? {
        guard let reader else { return nil }
        if case .available(let data) = await reader.frame(for: evidence, maxHeight: maxHeight) {
            return NSImage(data: data)
        }
        return nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// 菜单里的"立即同步"：处理积压的活动，再把结果写入记忆。忽略电源节流。
    func syncNow() {
        Task {
            _ = await pipeline?.runOnce(force: true)
            await memorySync?.syncOnce()
            lastMemoryScan = .distantPast
            await refresh()
        }
    }

    /// 只在异常时出现在菜单里的问题，每个都附带建议操作。正常运行时为空。
    var issues: [AppIssue] {
        var list: [AppIssue] = []
        if let startupError {
            list.append(AppIssue(id: "startup", message: startupError, action: nil))
            return list
        }
        if let warning = configWarning {
            list.append(AppIssue(id: "config", message: warning, action: .revealConfig))
        }
        if let status {
            switch status.state {
            case .permissionMissing:
                list.append(AppIssue(
                    id: "permission",
                    message: "需要屏幕录制权限才能记录。在系统设置中允许后，需要重新启动 Amai 才会生效",
                    actions: [.grantScreenRecording, .relaunch]
                ))
            case .error:
                let detail = status.screen.lastError.map { "（\($0)）" } ?? ""
                list.append(AppIssue(id: "capture", message: "截图连续失败\(detail)，稍后会自动重试", action: .openInspector))
            default:
                break
            }
        }
        if !modelInstalled {
            list.append(AppIssue(id: "model", message: "本地模型未安装，无法整理屏幕活动", action: .openSettings))
        } else if let e = extractionStatus {
            switch e.state {
            case .modelUnavailable:
                list.append(AppIssue(id: "model", message: e.lastError ?? "本地模型不可用", action: .openSettings))
            case .retrying:
                list.append(AppIssue(id: "extraction", message: "处理屏幕活动时出错，稍后会自动重试", action: .openInspector))
            default:
                break
            }
        }
        if let err = memoryStatus?.lastError {
            list.append(AppIssue(id: "memory", message: err, action: .openInspector))
        }
        if let err = consolidationStatus?.lastError {
            list.append(AppIssue(id: "consolidation", message: err, action: .openSettings))
        }
        return list
    }

    /// 记忆目录中最新的文件修改时间。文件很少，扫描很便宜；每 15 秒最多一次。
    private func scanMemoryUpdate() {
        guard Date().timeIntervalSince(lastMemoryScan) > 15 else { return }
        lastMemoryScan = Date()
        let root = memoryRoot
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        var newest: Date?
        for case let url as URL in enumerator where url.pathExtension == "md" {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               newest.map({ d > $0 }) ?? true {
                newest = d
            }
        }
        lastMemoryUpdate = newest
    }

    private func refresh() async {
        scanMemoryUpdate()
        if let coordinator { status = await coordinator.status() }
        if let pipeline { extractionStatus = await pipeline.status }
        if let memorySync { memoryStatus = await memorySync.status }
        if let consolidator { consolidationStatus = await consolidator.status }
        chatGPTStatus = await chatGPT.status
    }
}

/// 菜单中显示的异常及建议操作。
struct AppIssue: Identifiable, Equatable {
    enum Action: Equatable {
        case grantScreenRecording
        case openSettings
        case openInspector
        case revealConfig
        case relaunch

        var title: String {
            switch self {
            case .grantScreenRecording: "打开屏幕录制设置…"
            case .openSettings: "打开设置…"
            case .openInspector: "查看详情…"
            case .revealConfig: "显示配置文件"
            case .relaunch: "重新启动 Amai"
            }
        }
    }

    let id: String
    let message: String
    let actions: [Action]

    init(id: String, message: String, action: Action?) {
        self.init(id: id, message: message, actions: action.map { [$0] } ?? [])
    }

    init(id: String, message: String, actions: [Action]) {
        self.id = id
        self.message = message
        self.actions = actions
    }
}
