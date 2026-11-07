// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import struct AmaiCore.ActivitySegment
import enum AmaiCore.AmaiLog
import enum AmaiCore.MemoryLanguage
import struct AmaiCore.AmaiPaths
import struct AmaiCore.Evidence
import enum AmaiCore.FrameAvailability
import protocol AmaiCore.PerceptionReading
import struct AmaiCore.TimeRange
import AmaiCloud
import AmaiExtraction
import AmaiMemory
import AmaiMemoryUI
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
    /// 记忆迁移（Schema v1）失败的原因。失败时旧文件原样保留，暂停记忆整理，daily 同步照常。
    private(set) var migrationError: String?
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
    /// 设置界面只读展示用（截图间隔、原始数据保留、排除的应用）。这些项在配置文件中修改，重启后生效。
    var perceptionConfiguration: PerceptionConfiguration { configuration.perception }
    private let localModel: MLXModelProvider?
    /// 本次启动实际使用的本地模型。设置中改选后写入配置，重启后生效。
    let modelTag: String
    /// 配置中选定的本地模型（可能与 `modelTag` 不同，等待重启）。
    var selectedModelTag: String { configuration.extraction.modelTag }
    /// 正在进行的模型下载：标签 → 进度（nil 表示准备中）。
    private(set) var modelDownloads: [String: Double?] = [:]
    private(set) var modelDownloadErrors: [String: String] = [:]
    /// 已安装状态的版本号：下载完成后递增，让设置页重新检查磁盘。
    private(set) var installedModelsVersion = 0
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// 递增时主窗口打开设置窗口（供开发预览的截图流程使用）。
    var settingsRequests = 0
    let memoryRoot: URL

    private let paths: AmaiPaths?
    private let coordinator: PerceptionCoordinator?
    let reader: (any PerceptionReading)?
    let extractionStore: ExtractionStore?
    private let pipeline: ExtractionPipeline?
    private let memorySync: MemorySync?
    private let memoryStore: MemoryStore?
    private let consolidator: Consolidator?
    let memoryIndex: MemoryIndex?
    private var pollTask: Task<Void, Never>?

    /// 开发用的隔离预览模式（`--memory-preview <目录>`）：只打开记忆窗口浏览该目录下的 memory/，
    /// 时间线读取 support/extracted/ 中的合成片段。
    let isMemoryPreview: Bool

    private enum PreviewMode: Error { case ready }

    private static func memoryPreviewDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--memory-preview"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }

    init() {
        var paths: AmaiPaths?
        var coordinator: PerceptionCoordinator?
        var reader: SpoolReader?
        var store: ExtractionStore?
        var pipeline: ExtractionPipeline?
        var memorySync: MemorySync?
        var store_: MemoryStore?
        var memoryIndex: MemoryIndex?
        var consolidator: Consolidator?
        var localModel: MLXModelProvider?
        let keychain = KeychainStore()
        // 浏览器授权：用系统默认浏览器打开 OpenAI 授权页。预览模式不读钥匙串。
        let chatGPT = ChatGPTSession(store: Self.memoryPreviewDirectory() == nil ? keychain : InMemorySecretStore(), openURL: { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        })
        var claudeWorkdir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-claude-cli")
        var configWarning: String?
        var startupError: String?
        var migrationError: String?
        var config = AppConfiguration.default
        let preview = Self.memoryPreviewDirectory()
        do {
            if let preview {
                // 隔离预览：只浏览给定目录中的记忆。不读真实配置，不创建采集、抽取、同步、整理与任何模型客户端。
                let resolved = AmaiPaths(root: preview.appendingPathComponent("support", isDirectory: true))
                try resolved.ensureDirectories()
                paths = resolved
                config.memory = MemoryConfiguration(root: preview.appendingPathComponent("memory", isDirectory: true).path)
                memoryIndex = MemoryIndex(
                    root: config.memory.rootURL,
                    database: try MemoryIndexDatabase(path: resolved.index.appendingPathComponent("memory.sqlite").path)
                )
                // 只读取预览目录中已有的合成片段供时间线展示；没有抽取流水线写入。
                store = try ExtractionStore(root: resolved.extracted)
                throw PreviewMode.ready
            }
            let resolved = try AmaiPaths.standard()
            try resolved.ensureDirectories()
            let loaded = ConfigStore.load(from: resolved.config)
            config = loaded.configuration
            configWarning = loaded.error
            // 首次启动：记忆语言按系统首选语言设定一次并保存，之后不再跟随系统。配置读取出错时不写，避免覆盖原文件。
            if !config.memory.languageIsExplicit, loaded.error == nil {
                config.memory.language = MemoryLanguage.initial(preferredLanguages: Locale.preferredLanguages)
                try? ConfigStore.save(config, to: resolved.config)
            }
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
            var extractionOptions = ExtractionPipeline.Options()
            extractionOptions.language = config.memory.language
            let built = ExtractionPipeline(dependencies: .init(
                reader: spoolReader,
                model: model,
                ocr: VisionTextRecognizer(),
                store: extractedStore,
                shouldRun: heavyWorkAllowed
            ), options: extractionOptions)
            pipeline = built

            // 先把旧布局（summary.md、work/ 等）迁移到 Schema v1，再启动同步与整理，避免整理读写到一半迁移的文件。
            do {
                let migrated = try SchemaMigration(root: config.memory.rootURL).migrate()
                if !migrated.migrated.isEmpty {
                    AmaiLog.logger("app").info("memory schema v1 migration: \(migrated.migrated.count) files, \(migrated.itemsCarried) items")
                }
            } catch {
                migrationError = String(localized: "记忆迁移未完成，旧文件已原样保留：\(String(describing: error))")
                AmaiLog.logger("app").error("memory migration failed: \(String(describing: error), privacy: .public)")
            }
            let memoryStore = try MemoryStore(root: config.memory.rootURL, language: config.memory.language)
            store_ = memoryStore
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
            var consolidationOptions = Consolidator.Options()
            consolidationOptions.language = config.memory.language
            consolidator = Consolidator(
                store: memoryStore,
                source: ExtractionSegmentSource(store: extractedStore),
                model: ConsolidationModelFactory.make(config.consolidationModel, context: ConsolidationModelContext(
                    local: model, keychain: keychain, chatGPT: chatGPT,
                    claudeWorkdir: resolved.root.appendingPathComponent("claude-cli", isDirectory: true)
                )),
                snapshots: SnapshotStore(root: resolved.root.appendingPathComponent("snapshots", isDirectory: true)),
                stateURL: resolved.index.appendingPathComponent("consolidation.json"),
                options: consolidationOptions,
                shouldRun: heavyWorkAllowed
            )
        } catch PreviewMode.ready {
            AmaiLog.logger("app").info("memory preview mode")
        } catch {
            startupError = String(localized: "初始化失败：\(String(describing: error))")
            AmaiLog.logger("app").error("startup failed: \(String(describing: error), privacy: .public)")
        }
        self.paths = paths
        self.coordinator = coordinator
        self.reader = reader
        self.extractionStore = store
        self.pipeline = pipeline
        self.memorySync = memorySync
        self.memoryStore = store_
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
        self.migrationError = migrationError
        self.modelTag = config.extraction.modelTag
        self.modelInstalled = LocalInferenceBackend.isInstalled(tag: config.extraction.modelTag)
        self.isMemoryPreview = preview != nil
        self.showsOnboarding = preview == nil
            ? startupError == nil && Self.needsOnboarding()
            : CommandLine.arguments.contains("--onboarding-tour")

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
        // 迁移失败时不启动整理：整理会写 general.md / work.md，而旧文件还没搬完。
        if let consolidator, migrationError == nil {
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

        // 开发用启动参数：open .build/Amai.app --args --consolidate-today [--update-general]
        let args = CommandLine.arguments
        if migrationError == nil, args.contains("--consolidate-today") || args.contains("--update-general") {
            Task { [weak self] in
                guard let self, let consolidator = self.consolidator, let memorySync = self.memorySync else { return }
                await memorySync.syncOnce()
                if args.contains("--consolidate-today") { _ = try? await consolidator.consolidateDay(Date()) }
                if args.contains("--update-general") { _ = try? await consolidator.updateGeneral() }
                await memorySync.syncOnce()
                await self.refresh()
            }
        }
        if isMemoryPreview, let i = args.firstIndex(of: "--memory-preview-tour"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { await MemoryPreviewTour.run(model: self, output: output) }
        }
        if isMemoryPreview, let i = args.firstIndex(of: "--onboarding-tour"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { await MemoryPreviewTour.runOnboarding(model: self, output: output) }
        }
        // 开发用：用合成场景评测记忆整理，只在临时目录中运行，不读写真实记忆。
        // open .build/Amai.app --args --memory-eval <scenarios.json> --eval-output <目录> [--eval-local]
        if let i = args.firstIndex(of: "--memory-eval"), i + 1 < args.count, let context = modelContext {
            let scenarios = URL(fileURLWithPath: args[i + 1])
            let output = args.firstIndex(of: "--eval-output").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("amai-memory-eval")
            var config = consolidationModel
            if args.contains("--eval-local") { config.mode = .local }
            let model = ConsolidationModelFactory.make(config, context: context)
            Task.detached {
                await MemoryEvalCommand.run(scenarios: scenarios, output: output, model: model)
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

    // MARK: - Onboarding

    private static let onboardingCompletedKey = "amai.onboardingCompleted"

    /// 只有从未开始过记录的新用户才需要引导；在引导出现之前就用过 Amai 的用户（记录过采集状态）直接视为已完成。
    private static func needsOnboarding() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: onboardingCompletedKey) { return false }
        if defaults.string(forKey: captureIntentKey) != nil {
            defaults.set(true, forKey: onboardingCompletedKey)
            return false
        }
        return true
    }

    let onboarding = OnboardingState()
    /// 引导未完成：菜单只保留"继续设置"与"退出"，也不开始记录。
    private(set) var showsOnboarding: Bool
    private let screenRecordingGrantedAtLaunch = ScreenRecordingPermission.isGranted()

    /// 引导中的选择有些要重启才生效：新授予的屏幕录制权限、界面语言、改选的本地模型。
    var onboardingNeedsRelaunch: Bool {
        guard !isMemoryPreview else { return false }
        return (onboarding.screenRecordingGranted && !screenRecordingGrantedAtLaunch)
            || interfaceLanguage != interfaceLanguageAtLaunch
            || selectedModelTag != modelTag
    }

    /// 配置中选定的本地模型是否已下载（下载完成后重新检查）。
    var selectedModelInstalled: Bool {
        _ = installedModelsVersion
        return LocalInferenceBackend.isInstalled(tag: selectedModelTag)
    }

    /// 从设置中重新打开引导。已在记录的用户完成时保持原来的记录状态。
    func reopenOnboarding() {
        onboarding.step = .welcome
        onboarding.memoryModelApplied = false
        showsOnboarding = true
    }

    /// 完成引导并开始记录；需要重启时只记下"开始记录"，由重启后的恢复流程开始采集。
    func finishOnboarding() {
        showsOnboarding = false
        guard !isMemoryPreview else { return }
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        if onboardingNeedsRelaunch {
            if captureIntent == nil { captureIntent = .running }
            relaunch()
        } else if captureIntent == nil {
            start()
        }
    }

    func requestScreenRecording() {
        guard !isMemoryPreview else { return }
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

    // MARK: - Memory browser

    /// 主窗口的界面状态（当前页面、日期、搜索等）。从菜单打开主窗口时重置为「综合」。
    let memoryBrowser = MemoryBrowserController()

    /// 记忆窗口使用的只读接口（与今后的外部 Agent 接入共用）。
    var memoryLibrary: MemoryLibrary {
        MemoryLibrary(root: memoryRoot, index: memoryIndex)
    }

    var memoryBrowserEnvironment: MemoryBrowserEnvironment {
        let index = memoryIndex
        let library = memoryLibrary
        return MemoryBrowserEnvironment(
            library: library,
            search: { query in
                guard let index else { return [] }
                // 先增量刷新索引，纳入用户刚在编辑器里做的修改。
                _ = try? await index.refresh()
                return (try? await library.search(query, limit: 40)) ?? []
            },
            openFile: { [weak self] url in self?.openMemoryFile(url) },
            reveal: { [weak self] url in self?.revealInFinder(url) }
        )
    }

    /// 用默认应用打开记忆文件（Markdown 编辑器）。
    func openMemoryFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 在访达中显示记忆文件或文件夹。
    func revealInFinder(_ url: URL?) {
        let target = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? memoryRoot
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// 手动整理今天：生成今天的日终摘要并整理路由到的分区（不影响凌晨的正式整理）。
    func consolidateToday() {
        guard let consolidator, let memorySync, migrationError == nil else { return }
        Task {
            await memorySync.syncOnce()
            _ = try? await consolidator.consolidateDay(Date())
            await memorySync.syncOnce()
            await refresh()
        }
    }

    func updateGeneralNow() {
        guard let consolidator, let memorySync, migrationError == nil else { return }
        Task {
            _ = try? await consolidator.updateGeneral()
            await memorySync.syncOnce()
            await refresh()
        }
    }

    // MARK: - Consolidation model

    var consolidationModelLabel: String {
        ConsolidationModelFactory.label(consolidationModel, localIdentifier: localModel?.identifier ?? String(localized: "本地模型"))
    }

    private var modelContext: ConsolidationModelContext? {
        guard let localModel else { return nil }
        return ConsolidationModelContext(local: localModel, keychain: keychain, chatGPT: chatGPT, claudeWorkdir: claudeWorkdir)
    }

    /// 保存整理模型配置并立即切换。返回错误说明（成功为 nil）。
    func applyConsolidationModel(_ new: ConsolidationModelConfiguration) async -> String? {
        guard let paths, let context = modelContext, let consolidator else { return String(localized: "应用未正确初始化") }
        var updated = configuration
        updated.consolidationModel = new
        do {
            try ConfigStore.save(updated, to: paths.config)
        } catch {
            return String(localized: "保存配置失败：\(String(describing: error))")
        }
        configuration = updated
        consolidationModel = new
        await consolidator.setModel(ConsolidationModelFactory.make(new, context: context))
        AmaiLog.logger("app").info("consolidation model switched to \(new.mode.rawValue, privacy: .public)")
        return nil
    }

    // MARK: - Local model

    /// 保存选定的本地模型。模型实例由抽取与本地整理共用，启动时创建，所以重启后生效。返回错误说明（成功为 nil）。
    // MARK: - Interface language

    /// 界面语言。写入本应用偏好中的 AppleLanguages（与系统设置里"按 App 设置语言"是同一个设置），重启后生效。
    enum InterfaceLanguage: String, CaseIterable {
        case system, zhHans = "zh-Hans", en, ja

        var title: String {
            switch self {
            case .system: String(localized: "跟随系统")
            case .zhHans: "简体中文"
            case .en: "English"
            case .ja: "日本語"
            }
        }
    }

    /// 启动时生效的界面语言，用来判断是否需要重启。
    let interfaceLanguageAtLaunch = AppModel.storedInterfaceLanguage()

    var interfaceLanguage: InterfaceLanguage {
        get { access(keyPath: \.interfaceLanguage); return Self.storedInterfaceLanguage() }
        set {
            withMutation(keyPath: \.interfaceLanguage) {
                if newValue == .system {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
                }
            }
        }
    }

    /// 只看本应用自己的偏好，不看全局语言列表（全局列表总是存在，无法区分"跟随系统"）。
    private static func storedInterfaceLanguage() -> InterfaceLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let code = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return InterfaceLanguage(rawValue: code) ?? .system
    }

    // MARK: - Memory language

    /// 记忆语言（之后新写入或修改的记忆内容使用的语言）。
    var memoryLanguage: MemoryLanguage { configuration.memory.language }

    /// 切换记忆语言：保存到配置，立即对之后的抽取与整理生效；已写入的内容不变。
    func setMemoryLanguage(_ language: MemoryLanguage) -> String? {
        guard let paths, !isMemoryPreview else { return String(localized: "预览模式不能修改设置") }
        guard language != configuration.memory.language else { return nil }
        var updated = configuration
        updated.memory.language = language
        do {
            try ConfigStore.save(updated, to: paths.config)
        } catch {
            return String(localized: "保存配置失败：\(String(describing: error))")
        }
        configuration = updated
        let (pipeline, consolidator, store) = (pipeline, consolidator, memoryStore)
        Task {
            await pipeline?.setLanguage(language)
            await consolidator?.setLanguage(language)
            await store?.setLanguage(language)
        }
        AmaiLog.logger("app").info("memory language set to \(language.rawValue, privacy: .public)")
        return nil
    }

    func selectLocalModel(_ tag: String) -> String? {
        guard let paths, !isMemoryPreview else { return String(localized: "预览模式不能修改设置") }
        var updated = configuration
        updated.extraction.modelTag = tag
        do {
            try ConfigStore.save(updated, to: paths.config)
        } catch {
            return String(localized: "保存配置失败：\(String(describing: error))")
        }
        configuration = updated
        AmaiLog.logger("app").info("local model selected: \(tag, privacy: .public)")
        return nil
    }

    func downloadLocalModel(_ tag: String) {
        guard downloadTasks[tag] == nil else { return }
        modelDownloads[tag] = .some(nil)
        modelDownloadErrors[tag] = nil
        downloadTasks[tag] = Task { [weak self] in
            do {
                for try await event in LocalModelDownloader.download(tag: tag) {
                    switch event {
                    case .preparing: self?.modelDownloads[tag] = .some(nil)
                    case .downloading(let fraction): self?.modelDownloads[tag] = fraction
                    case .finished: break
                    }
                }
            } catch {
                self?.modelDownloadErrors[tag] = String(localized: "下载失败：\(error.localizedDescription)")
            }
            guard let self else { return }
            self.modelDownloads[tag] = nil
            self.downloadTasks[tag] = nil
            self.installedModelsVersion += 1
            if tag == self.modelTag { self.modelInstalled = LocalInferenceBackend.isInstalled(tag: tag) }
        }
    }

    /// 取消后已下载的部分留在缓存中，再次下载时继续。
    func cancelLocalModelDownload(_ tag: String) {
        downloadTasks[tag]?.cancel()
    }

    /// 用一个极小的请求测试连接，不发送任何记忆内容。
    func testConnection(_ config: ConsolidationModelConfiguration, apiKey: String?) async -> String {
        guard let context = modelContext else { return String(localized: "应用未正确初始化") }
        let client: any CloudTextClient
        if config.mode == .apiKey, let key = apiKey, !key.isEmpty {
            client = config.apiKeyClient(apiKey: key)
        } else {
            switch ConsolidationModelFactory.client(config, context: context) {
            case .success(let c): client = c
            case .failure(let error): return String(localized: "连接失败：\(error.description)")
            }
        }
        do {
            let response = try await client.generate(CloudRequest(system: "Reply with the single word OK.", user: "ping", maxTokens: 16))
            return String(localized: "连接成功：\(response.model)，用量 \(response.inputTokens) / \(response.outputTokens) token")
        } catch let error as CloudError {
            return String(localized: "连接失败：\(error.description)")
        } catch {
            return String(localized: "连接失败：\(error.localizedDescription)")
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
            return String(localized: "登录失败：\(error.localizedDescription)")
        }
    }

    /// 退出登录。撤销未确认时返回提示。
    func signOutChatGPT() async -> String? {
        let revoked = await chatGPT.signOut()
        await refreshChatGPTStatus()
        if consolidationModel.mode == .chatgptPlan { _ = await applyConsolidationModel(consolidationModel) }
        return revoked ? nil : String(localized: "未能确认撤销授权，请到 ChatGPT 设置中断开 Amai。本地令牌已清除。")
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
            return .failure(.toolNotFound(configuredPath.isEmpty ? String(localized: "未在常见位置找到 claude") : configuredPath))
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
        guard end > start else { return String(localized: "结束时间必须晚于开始时间") }
        var notes: [String] = []
        do {
            if let coordinator {
                let files = try await coordinator.erase(from: start, to: end)
                notes.append(String(localized: "删除原始视频分段 \(files) 个"))
            }
            let days = try await extractionStore?.deleteData(overlapping: TimeRange(start: start, end: end)) ?? []
            notes.append(String(localized: "影响 \(days.count) 天的抽取结果"))
            if let memorySync {
                for day in days { try await memorySync.rewrite(day: day) }
                await memorySync.syncOnce()
            }
            return notes.joined(separator: "，")
        } catch {
            return String(localized: "删除未完成：\(String(describing: error))。") + notes.joined(separator: "，")
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
                    message: String(localized: "需要屏幕录制权限才能记录。在系统设置中允许后，需要重新启动 Amai 才会生效"),
                    actions: [.grantScreenRecording, .relaunch]
                ))
            case .error:
                let detail = status.screen.lastError.map { "（\($0)）" } ?? ""
                list.append(AppIssue(id: "capture", message: String(localized: "截图连续失败\(detail)，稍后会自动重试"), action: .openStatus))
            default:
                break
            }
        }
        if !modelInstalled {
            list.append(AppIssue(id: "model", message: String(localized: "本地模型未安装，无法整理屏幕活动"), action: .openLocalModels))
        } else if let e = extractionStatus {
            switch e.state {
            case .modelUnavailable:
                list.append(AppIssue(id: "model", message: e.lastError ?? String(localized: "本地模型不可用"), action: .openLocalModels))
            case .retrying:
                list.append(AppIssue(id: "extraction", message: String(localized: "处理屏幕活动时出错，稍后会自动重试"), action: .openStatus))
            default:
                break
            }
        }
        if let migrationError {
            list.append(AppIssue(id: "migration", message: migrationError, action: nil))
        }
        if let err = memoryStatus?.lastError {
            list.append(AppIssue(id: "memory", message: err, action: .openStatus))
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
        // 预览模式不读取钥匙串中的账号信息。
        if !isMemoryPreview { chatGPTStatus = await chatGPT.status }
    }
}

/// 菜单中显示的异常及建议操作。
struct AppIssue: Identifiable, Equatable {
    enum Action: Equatable {
        case grantScreenRecording
        case openSettings
        case openLocalModels
        case openStatus
        case revealConfig
        case relaunch

        var title: String {
            switch self {
            case .grantScreenRecording: String(localized: "打开屏幕录制设置…")
            case .openSettings: String(localized: "打开设置…")
            case .openLocalModels: String(localized: "选择本地模型…")
            case .openStatus: String(localized: "查看运行状态…")
            case .revealConfig: String(localized: "显示配置文件")
            case .relaunch: String(localized: "重新启动 Amai")
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
