import AmaiCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// 纯文本本地模型的一次性对话入口（例如 Qwen2.5-Instruct），只用于开发时的评测（问答评测的 Judge）。
///
/// App 的 `LocalModelHost` 只用 VLM 工厂加载（屏幕理解必须有视觉能力），加载不了纯文本模型；
/// 这里单独用 LLM 工厂加载，不进入 `LocalModelRuntime` 的共享登记，不改变 App 的任何加载路径。
/// 每次请求新建会话：没有 KV cache 复用、不支持图片与工具。模型未在本地时直接报错，不下载。
public struct MLXTextChatModel: ChatModel {
    public let modelTag: String
    public let identifier: String
    public let sendsDataOffDevice = false
    public let supportsImages = false
    public let supportsTools = false
    private let holder: Holder

    public init(modelTag: String) {
        self.modelTag = modelTag
        self.identifier = MLXModelProvider.identifier(for: modelTag)
        self.holder = Holder(modelTag: modelTag)
    }

    public var isInstalled: Bool { LocalInferenceBackend.isInstalled(tag: modelTag) }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let holder = holder
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await holder.respond(request)
                    continuation.yield(.text(text))
                    continuation.yield(.finished(ChatUsage()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 释放权重。
    public func unload() async { await holder.unload() }

    actor Holder {
        let modelTag: String
        private var container: ModelContainer?

        init(modelTag: String) { self.modelTag = modelTag }

        func respond(_ request: ChatRequest) async throws -> String {
            guard LocalInferenceBackend.isInstalled(tag: modelTag) else { throw ModelProviderError.modelNotInstalled(modelTag) }
            let container = try await load()
            var params = GenerateParameters()
            params.maxTokens = request.maxTokens
            params.temperature = request.temperature
            // 之前的轮次作为历史交给会话；最后一条 user 消息是这次要回答的。
            guard let last = request.messages.last, last.role == .user else { return "" }
            let history: [Chat.Message] = request.messages.dropLast().compactMap { message in
                switch message.role {
                case .user: .user(message.text)
                case .assistant: .assistant(message.text)
                case .tool: nil
                }
            }
            let session = MLXLMCommon.ChatSession(
                container, instructions: request.system.isEmpty ? nil : request.system, history: history,
                generateParameters: params
            )
            do {
                return ThinkingFilter.clean(try await session.respond(to: last.text))
            } catch {
                throw ModelProviderError.generationFailed(String(describing: type(of: error)))
            }
        }

        func unload() {
            container = nil
            MLX.Memory.clearCache()
        }

        private func load() async throws -> ModelContainer {
            if let container { return container }
            do {
                let loaded = try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelTag)
                )
                container = loaded
                return loaded
            } catch {
                throw ModelProviderError.loadFailed("\(modelTag) could not be loaded as a text model: \(error)")
            }
        }
    }
}
