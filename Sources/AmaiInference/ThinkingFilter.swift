import Foundation

/// 从流式输出中去掉思考块（`<think>…</think>`、Gemma 的 `<|channel>…<channel|>`）。
/// 标记可能被切在两个分片之间，所以可能是标记开头的尾部先留着，等下一个分片再判断。
public struct ThinkingFilter: Sendable {
    static let markers: [(open: String, close: String)] = [("<think>", "</think>"), ("<|channel>", "<channel|>")]

    private var pending = ""
    private var closing: String?

    public init() {}

    /// 送入一个分片，返回可以立即显示的文本。
    public mutating func feed(_ chunk: String) -> String {
        pending += chunk
        var output = ""
        while true {
            if let close = closing {
                guard let range = pending.range(of: close) else {
                    // 仍在思考块内：只保留可能是结束标记开头的尾部。
                    pending = String(pending.suffix(close.count - 1))
                    return output
                }
                pending = String(pending[range.upperBound...])
                closing = nil
                continue
            }
            let hit = Self.markers
                .compactMap { marker in pending.range(of: marker.open).map { (range: $0, close: marker.close) } }
                .min { $0.range.lowerBound < $1.range.lowerBound }
            if let hit {
                output += pending[..<hit.range.lowerBound]
                pending = String(pending[hit.range.upperBound...])
                closing = hit.close
                continue
            }
            let hold = Self.heldSuffixLength(pending)
            output += pending.dropLast(hold)
            pending = String(pending.suffix(hold))
            return output
        }
    }

    /// 流结束时调用：吐出还留着的普通文本（未闭合的思考块丢弃）。
    public mutating func finish() -> String {
        defer { pending = "" }
        return closing == nil ? pending : ""
    }

    /// 文本末尾有多少个字符可能是某个开始标记的前缀。
    private static func heldSuffixLength(_ text: String) -> Int {
        let longest = markers.map(\.open.count).max() ?? 0
        for length in stride(from: min(longest - 1, text.count), to: 0, by: -1) {
            let tail = text.suffix(length)
            if markers.contains(where: { $0.open.hasPrefix(tail) }) { return length }
        }
        return 0
    }

    /// 一次性清理完整文本，并去掉首尾空白。
    public static func clean(_ text: String) -> String {
        var filter = ThinkingFilter()
        let body = filter.feed(text) + filter.finish()
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
