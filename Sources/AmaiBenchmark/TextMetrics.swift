import CryptoKit
import Foundation

/// 文字比较：OCR 的字符错误率、关键词命中。
public enum TextMetrics {
    /// OCR 比较用的归一化：Unicode 兼容分解（全角 → 半角）、小写、去掉所有空白。
    /// 空白不计入：Vision 对 CJK 文本是否插入空格不稳定，而这对下游没有影响。
    public static func normalizeForOCR(_ text: String) -> [Character] {
        Array(text.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace })
    }

    /// 编辑距离（插入、删除、替换各算 1）。
    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 字符错误率：编辑距离 / 参考文字长度（可能大于 1）。返回编辑距离与参考长度，便于跨样本汇总。
    public static func characterErrors(reference: String, hypothesis: String) -> (errors: Int, length: Int) {
        let r = normalizeForOCR(reference), h = normalizeForOCR(hypothesis)
        return (editDistance(r, h), r.count)
    }

    /// 参考行中被完整识别出来的行数（归一化后作为子串出现在识别结果中）。
    public static func linesRecovered(reference: [String], hypothesis: String) -> Int {
        let h = String(normalizeForOCR(hypothesis))
        return reference.filter { line in
            let r = String(normalizeForOCR(line))
            return !r.isEmpty && h.contains(r)
        }.count
    }

    /// 关键词是否出现（与 QA 评测相同的归一化：只保留字母数字、小写）。
    public static func contains(_ text: String, _ anchor: String) -> Bool {
        let n = anchorNormalize(anchor)
        return !n.isEmpty && anchorNormalize(text).contains(n)
    }

    public static func anchorNormalize(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(file url: URL) -> String {
        sha256((try? Data(contentsOf: url)) ?? Data())
    }
}
