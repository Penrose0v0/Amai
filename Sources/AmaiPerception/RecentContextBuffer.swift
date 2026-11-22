import AmaiCore
import Foundation

/// 最近几分钟里屏幕出现过的"有意义的状态"，只在内存中、容量与时间都有上限。
///
/// 一个状态 = 某个应用的一屏画面（压缩后的 JPEG）。新状态在应用切换或画面明显变化时产生；
/// 同一应用里的小变化（打字、滚动几行）只更新最后一个状态，不新增。
/// 文字不在这里提取：只有当有人来读（用户唤起 Agent）时才对还没有文字的状态做 OCR 并缓存，
/// 所以没人用 Agent 时这里没有任何识别或模型开销。
struct RecentContextBuffer {
    struct State {
        var firstSeen: Date
        var lastSeen: Date
        var appName: String?
        var bundleId: String?
        var windowTitle: String?
        var jpeg: Data
        var fingerprint: ScreenFingerprint
        var hash: UInt64 { fingerprint.layoutHash }
        /// 按需 OCR 的结果；画面更新后清空。
        var text: String?
    }

    /// 最多保留的状态数。
    var capacity = 5
    /// 状态的最长保留时间。
    var maxAge: TimeInterval = 300
    /// 同一应用内，dHash 距离达到此值才算"换了一屏"（64 位中的位数）。
    var newStateDistance = 12

    private(set) var states: [State] = []

    enum Change: Equatable {
        case unchanged
        case updated
        case added
    }

    /// 记录一次观察到的画面。`encode` 只在确实需要保存画面时调用（编码有成本）。
    @discardableResult
    mutating func note(
        fingerprint: ScreenFingerprint, appName: String?, bundleId: String?, windowTitle: String?, at now: Date,
        encode: () -> Data?
    ) -> Change {
        prune(now: now)
        if let last = states.indices.last, states[last].bundleId == bundleId {
            // 版式没变、只换了文字（聊天来了新消息、列表翻页）也要更新画面，之后按需重新 OCR。
            if states[last].fingerprint.isSameScreen(as: fingerprint) {
                states[last].lastSeen = now
                return .unchanged
            }
            if states[last].fingerprint.layoutDistance(fingerprint) < newStateDistance {
                guard let jpeg = encode() else { return .unchanged }
                states[last].jpeg = jpeg
                states[last].fingerprint = fingerprint
                states[last].lastSeen = now
                states[last].text = nil
                if let windowTitle { states[last].windowTitle = windowTitle }
                return .updated
            }
        }
        guard let jpeg = encode() else { return .unchanged }
        states.append(State(
            firstSeen: now, lastSeen: now, appName: appName, bundleId: bundleId, windowTitle: windowTitle,
            jpeg: jpeg, fingerprint: fingerprint, text: nil
        ))
        if states.count > capacity { states.removeFirst(states.count - capacity) }
        return .added
    }

    /// 这帧画面与最后一个状态是否是同一屏（是的话 `note` 只会刷新时间）。
    func isSameAsLast(fingerprint: ScreenFingerprint, bundleId: String?) -> Bool {
        guard let last = states.last, last.bundleId == bundleId else { return false }
        return last.fingerprint.isSameScreen(as: fingerprint)
    }

    mutating func prune(now: Date) {
        states.removeAll { now.timeIntervalSince($0.lastSeen) > maxAge }
    }

    mutating func setText(_ text: String, at index: Int) {
        guard states.indices.contains(index) else { return }
        states[index].text = text
    }

    mutating func clear() {
        states.removeAll()
    }

    /// 去掉文字几乎相同的旧状态（来回切换同一个窗口时常见），从旧到新返回。没有文字的状态不返回。
    func distinctStates(similarity threshold: Double = 0.8) -> [RecentTextState] {
        var kept: [(state: State, lines: Set<String>)] = []
        for state in states.reversed() {
            guard let text = state.text, !text.isEmpty else { continue }
            let lines = ScreenTextSimilarity.lines(text)
            if kept.contains(where: { ScreenTextSimilarity.similarity($0.lines, lines) >= threshold }) { continue }
            kept.append((state, lines))
        }
        return kept.reversed().map { item in
            RecentTextState(
                firstSeen: item.state.firstSeen, lastSeen: item.state.lastSeen, appName: item.state.appName,
                windowTitle: item.state.windowTitle, text: item.state.text ?? "", source: .ocr
            )
        }
    }
}
