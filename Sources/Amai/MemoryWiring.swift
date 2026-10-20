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
}

/// 用抽取层的 ModelProvider 为记忆整理提供纯文本生成。
struct ProviderLanguageModel: MemoryLanguageModel {
    let provider: any ModelProvider

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await provider.generate(ModelRequest(cacheable: system, dynamic: user, maxTokens: maxTokens)).text
    }
}
