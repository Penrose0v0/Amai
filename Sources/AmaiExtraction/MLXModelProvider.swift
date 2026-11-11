import AmaiCore
import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

/// mlx-swift-lm 嵌入式本地 VLM（ADR-0002，参考 Eira 的 MLXClient）。
///
/// - 按需加载，空闲一段时间后卸载，后台常驻时不长期占用数 GB 内存；
/// - macOS 内存压力达到 critical 时立即卸载；
/// - 模型未在本地时直接报错，绝不在后台自动下载。
/// MVP 每次调用新建 ChatSession，不做 KV cache 复用。
public actor MLXModelProvider: ModelProvider {
    public nonisolated let identifier: String
    public nonisolated let sendsDataOffDevice = false
    public nonisolated let modelTag: String

    /// 与 LocalModelCatalog 保持一致。
    private static let knownConfigurations: [String: ModelConfiguration] = [
        "mlx-community/gemma-4-e2b-it-4bit": VLMRegistry.gemma4_E2B_it_4bit,
        "mlx-community/gemma-4-e4b-it-4bit": VLMRegistry.gemma4_E4B_it_4bit,
        "mlx-community/gemma-3-12b-it-qat-4bit": VLMRegistry.gemma3_12B_qat_4bit,
        "mlx-community/gemma-4-26b-a4b-it-4bit": VLMRegistry.gemma4_26BA4B_it_4bit,
    ]

    /// 限制 MLX 的缓冲复用池，图像 prefill 的临时缓冲在调用结束后归还系统（Eira 实测）。
    private static let cacheLimitBytes = 1024 * 1_048_576

    private let configuration: ModelConfiguration
    private let idleUnloadAfter: TimeInterval
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?
    private let memoryPressure: any DispatchSourceMemoryPressure
    private let log = AmaiLog.logger("extraction.model")

    public init(modelTag: String, idleUnloadAfter: TimeInterval = 300) {
        self.modelTag = modelTag
        self.identifier = "mlx:" + (modelTag.split(separator: "/").last.map(String.init) ?? modelTag)
        self.configuration = Self.knownConfigurations[modelTag] ?? ModelConfiguration(id: modelTag)
        self.idleUnloadAfter = idleUnloadAfter
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        self.memoryPressure = source
        source.setEventHandler { [weak self] in
            Task { await self?.unload(reason: "memory pressure") }
        }
        source.resume()
    }

    public var isLoaded: Bool { container != nil }

    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        guard LocalInferenceBackend.isInstalled(tag: modelTag) else {
            throw ModelProviderError.modelNotInstalled(modelTag)
        }
        unloadTask?.cancel()
        let started = Date()
        let container = try await loadContainer()

        var params = GenerateParameters()
        params.maxTokens = request.maxTokens
        params.temperature = request.temperature
        let session = ChatSession(
            container,
            instructions: request.cacheable.isEmpty ? nil : request.cacheable,
            generateParameters: params
        )
        let images: [UserInput.Image] = request.images
            .compactMap { CIImage(data: $0) }
            .map { .ciImage($0) }

        let raw: String
        do {
            raw = try await session.respond(to: request.dynamic, images: images, videos: [], audios: [])
        } catch {
            scheduleUnload()
            throw ModelProviderError.generationFailed(String(describing: type(of: error)))
        }
        scheduleUnload()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ModelResponse(text: Self.clean(raw), provider: identifier, latencyMs: ms)
    }

    public func unload(reason: String) {
        guard container != nil || loadTask != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        container = nil
        MLX.Memory.clearCache()
        log.info("model unloaded (\(reason, privacy: .public))")
    }

    // MARK: - Private

    private func loadContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        let config = configuration
        let tag = modelTag
        // 只用 VLM 工厂加载：通用的 loadModelContainer 会在 VLM 加载失败时静默改用 LLM 工厂，
        // 得到一个能回答文字、却看不到截图的模型（Gemma 4 E4B 曾因此只靠 OCR 文字描述屏幕）。
        // 屏幕理解必须有视觉能力，所以 VLM 加载失败就明确报错。
        let task = Task<ModelContainer, Error> {
            do {
                return try await VLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: config
                )
            } catch {
                throw ModelProviderError.loadFailed("\(tag) could not be loaded as a vision model: \(error)")
            }
        }
        loadTask = task
        let started = Date()
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            MLX.Memory.cacheLimit = Self.cacheLimitBytes
            log.info("model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let delay = idleUnloadAfter
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.unload(reason: "idle")
        }
    }

    /// 去掉可能出现的思考块与首尾空白。
    static func clean(_ text: String) -> String {
        var t = text
        for (open, close) in [("<think>", "</think>"), ("<|channel>", "<channel|>")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
