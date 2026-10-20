// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import struct AmaiCore.ActivitySegment
import enum AmaiCore.AmaiLog
import struct AmaiCore.AmaiPaths
import struct AmaiCore.Evidence
import enum AmaiCore.FrameAvailability
import protocol AmaiCore.PerceptionReading
import struct AmaiCore.TimeRange
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
    let modelTag: String
    let memoryRoot: URL

    private let paths: AmaiPaths?
    private let coordinator: PerceptionCoordinator?
    let reader: (any PerceptionReading)?
    let extractionStore: ExtractionStore?
    private let pipeline: ExtractionPipeline?
    private let memorySync: MemorySync?
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

            let perception = try PerceptionCoordinator(paths: resolved, configuration: config.perception)
            coordinator = perception
            let spoolReader = SpoolReader(spool: perception.spool)
            reader = spoolReader
            let extractedStore = try ExtractionStore(root: resolved.extracted)
            store = extractedStore
            let built = ExtractionPipeline(dependencies: .init(
                reader: spoolReader,
                model: MLXModelProvider(modelTag: config.extraction.modelTag),
                ocr: VisionTextRecognizer(),
                store: extractedStore,
                shouldRun: { [perception] in
                    // 电池低于 40%、低电量模式或过热时推迟推理，插电后追赶。
                    switch perception.currentPowerProfile {
                    case .performance, .balanced: true
                    case .saver, .paused: false
                    }
                }
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
        restoreCaptureState()
        startPolling()
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
            await memorySync?.stop()
            await pipeline?.stop()
            await coordinator?.stop()
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

    private func refresh() async {
        if let coordinator { status = await coordinator.status() }
        if let pipeline { extractionStatus = await pipeline.status }
        if let memorySync { memoryStatus = await memorySync.status }
    }
}
