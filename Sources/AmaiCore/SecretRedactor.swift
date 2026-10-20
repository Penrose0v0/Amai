import Foundation

/// 高风险字符串的脱敏（AGENTS.md §5）。用于 OCR 文本、模型输出落盘前，
/// 记忆层写入前也会复用。只覆盖形态明确的凭据，避免把普通内容误伤。
public enum SecretRedactor {
    public static let placeholder = "[已脱敏]"

    private static let patterns: [NSRegularExpression] = [
        #"sk-ant-[A-Za-z0-9_\-]{16,}"#,
        #"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"AIza[0-9A-Za-z_\-]{35}"#,
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let cardCandidate = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){13,19}\b"#)

    /// 返回脱敏后的文本与替换次数。
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.numberOfMatches(in: result, range: range)
            if matches > 0 {
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: placeholder)
                count += matches
            }
        }
        // 银行卡号：13–19 位数字且通过 Luhn 校验才替换。
        let range = NSRange(result.startIndex..., in: result)
        for match in cardCandidate.matches(in: result, range: range).reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            let digits = result[r].filter(\.isNumber)
            if digits.count >= 13, luhnValid(digits) {
                result.replaceSubrange(r, with: placeholder)
                count += 1
            }
        }
        return (result, count)
    }

    static func luhnValid<S: StringProtocol>(_ digits: S) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }
}
