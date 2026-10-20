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
