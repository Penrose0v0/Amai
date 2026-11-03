import AmaiCore
import AmaiExtraction
import AmaiMemory
import Foundation

/// 用抽取层的存储为记忆层提供活动片段。放在 App 里，记忆层与抽取层互不依赖。
struct ExtractionSegmentSource: SegmentSource {
    let store: ExtractionStore

    func daysWithUpdates(after: Date?, endingOn: Date, days: Int) async -> [(day: Date, latestUpdate: Date)] {
        await store.daysWithUpdates(after: after, endingOn: endingOn, days: days)
    }

    func segments(on day: Date) async -> [ActivitySegment] {
        await store.segments(on: day)
    }

    func observations(on day: Date) async -> [AmaiCoreObservation] {
        await store.observations(on: day)
    }
}

/// 本地模式：用抽取层的 ModelProvider 为记忆整理提供文本生成。不支持结构化输出，Schema 被忽略。
struct LocalLanguageModel: MemoryLanguageModel {
    let provider: any ModelProvider

    var identifier: String { provider.identifier }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        try await provider.generate(ModelRequest(cacheable: system, dynamic: user, maxTokens: maxTokens)).text
    }
}
