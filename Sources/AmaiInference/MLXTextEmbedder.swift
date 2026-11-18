import AmaiCore
import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// 记忆语义检索用的本地向量模型（mlx-swift-lm 的 MLXEmbedders，与对话模型同一个依赖包）。
///
/// 默认 Qwen3-Embedding-0.6B（4bit）：1024 维，支持中日英并且可以跨语言检索，下载约 330 MB。
/// 选它而不是更小的 multilingual-e5-small 的依据见 ADR-0011 的实测：改写与跨语言的问题命中率明显更高，
/// 而且相似度有可用的绝对刻度（E5 对任意两段文字都给出 0.75 以上，无法设门槛）。
///
/// 它是可选的：没有下载时 `isAvailable` 为 false，记忆检索只用关键词。
/// 与其他本地模型一样只由用户在设置中明确下载，按需加载，空闲后卸载，并经过 `InferenceGate`
/// （MLX 不能在多个任务里同时跑 GPU 计算；问题的向量按交互式优先级，批量补算按后台优先级）。
public struct MLXTextEmbedder: TextEmbedder {
    public static let defaultModelTag = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
    /// 下载大小（MB），用于设置界面的说明。
    public static let downloadMB = 330

    public let modelTag: String
    public let identifier: String
    /// 合成记忆库上的实测：无关内容的相似度中位数约 0.29、九成在 0.40 以下，相关内容平均 0.54。
    public let similarityRange: ClosedRange<Float> = 0.30...0.62
    private let host: Host
    private let profile: Profile

    /// 模型对输入的要求：问题前加任务说明，段落原样；取最后一个 token 做句向量，所以末尾要有结束符。
    struct Profile: Sendable {
        var queryPrefix = "Instruct: Given a question about the user's past activities and notes, retrieve the memory entries that answer it\nQuery:"
        var passagePrefix = ""
        var padToken = "<|endoftext|>"
        var endToken: String? = "<|endoftext|>"
        var maxTokens = 512
    }

    public init(modelTag: String = MLXTextEmbedder.defaultModelTag) {
        self.modelTag = modelTag
        self.identifier = "mlx:" + (modelTag.split(separator: "/").last.map(String.init) ?? modelTag)
        self.host = Host.shared(for: modelTag)
        self.profile = Profile()
    }

    public var isAvailable: Bool { LocalInferenceBackend.isInstalled(tag: modelTag) }

    public func embed(_ texts: [String], kind: TextEmbeddingKind) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard isAvailable else { throw ModelProviderError.modelNotInstalled(modelTag) }
        let prefix = kind == .query ? profile.queryPrefix : profile.passagePrefix
        return try await host.embed(texts.map { prefix + $0 }, profile: profile, priority: kind == .query ? .interactive : .background)
    }

    /// 提前加载权重（助手面板唤出时调用），让第一次检索不必等加载。
    public func warmUp() async {
        guard isAvailable else { return }
        _ = try? await host.embed([profile.queryPrefix + "warm up"], profile: profile, priority: .interactive)
    }

    public func unload() async {
        await host.unload()
    }

    actor Host {
        private static let hosts = EmbedderHosts()

        static func shared(for tag: String) -> Host {
            hosts.host(for: tag)
        }

        private let modelTag: String
        private var container: EmbedderModelContainer?
        private var unloadTask: Task<Void, Never>?
        private let log = AmaiLog.logger("inference.embedder")

        init(modelTag: String) {
            self.modelTag = modelTag
        }

        func embed(_ texts: [String], profile: Profile, priority: InferencePriority) async throws -> [[Float]] {
            let gate = InferenceGate.shared
            try await gate.acquire(priority)
            defer { gate.release(priority) }
            unloadTask?.cancel()
            defer { scheduleUnload() }
            let container = try await load()
            let limit = profile.maxTokens
            return await container.perform { context in
                let pad = context.tokenizer.convertTokenToId(profile.padToken) ?? 1
                let end = profile.endToken.flatMap { context.tokenizer.convertTokenToId($0) }
                let encoded = texts.map { text in
                    var ids = context.tokenizer.encode(text: text, addSpecialTokens: true)
                    if let end, ids.last != end { ids.append(end) }
                    if ids.count > limit, let last = ids.last { ids = Array(ids.prefix(limit - 1)) + [last] }
                    return ids
                }
                let length = encoded.map(\.count).max() ?? 1
                let padded = stacked(encoded.map { MLXArray($0 + Array(repeating: pad, count: length - $0.count)) })
                let mask = stacked(encoded.map {
                    MLXArray(Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: length - $0.count))
                })
                let output = context.model(
                    padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask
                )
                let pooled = context.pooling(output, mask: mask, normalize: true, applyLayerNorm: false)
                pooled.eval()
                return pooled.map { $0.asArray(Float.self) }
            }
        }

        func unload() {
            guard container != nil else { return }
            container = nil
            MLX.Memory.clearCache()
            log.info("embedder unloaded")
        }

        private func load() async throws -> EmbedderModelContainer {
            if let container { return container }
            let started = Date()
            do {
                let loaded = try await EmbedderModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelTag)
                )
                container = loaded
                log.info("embedder loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                return loaded
            } catch {
                throw ModelProviderError.loadFailed("\(modelTag): \(error)")
            }
        }

        private func scheduleUnload() {
            unloadTask?.cancel()
            unloadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await self?.unload()
            }
        }
    }
}

/// 每个模型标签一个 Host。
final class EmbedderHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: MLXTextEmbedder.Host] = [:]

    func host(for tag: String) -> MLXTextEmbedder.Host {
        lock.withLock {
            if let host = hosts[tag] { return host }
            let host = MLXTextEmbedder.Host(modelTag: tag)
            hosts[tag] = host
            return host
        }
    }
}
