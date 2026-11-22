import Foundation

/// 高风险字符串的脱敏（AGENTS.md §5）。用于 OCR 文本、模型输出落盘前，
/// 记忆层写入前也会复用。只覆盖形态明确的凭据，避免把普通内容误伤。
public enum SecretRedactor {
    public static let placeholder = "[已脱敏]"

    /// 前面不能紧贴字母或数字（新增规则使用）：标识符中间的 `hf_`、`npm_` 等不是凭据前缀。
    private static let start = #"(?<![A-Za-z0-9])"#

    /// 一条规则：匹配到的部分换成 `template`。默认整段换成占位符；
    /// 需要保留上下文（键名、连接串的用户名与主机）的规则用捕获组只替换秘密本身。
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let placeholderTemplate = NSRegularExpression.escapedTemplate(for: placeholder)

    private static let rules: [Rule] = [
        // PEM 私钥：开始行、随后的头部行（Proc-Type 等）与 base64 正文，以及结束行。正文才是秘密，不能只换掉开始行。
        // 屏幕上常常只露出一部分（滚动、窗口裁切），没有结束行时到 base64 行结束为止。
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:\s*?\n[ \t]*(?:[A-Za-z0-9+/=]{16,}|[A-Za-z][A-Za-z\-]*:[^\n]*))*(?:\s*?\n[ \t]*-----END [A-Z ]*PRIVATE KEY-----)?"#, false, nil),
        (#"sk-ant-[A-Za-z0-9_\-]{16,}"#, false, nil),
        (#"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#, false, nil),
        // Stripe 的 secret / restricted key（publishable key `pk_` 本来就公开，不处理）。
        (#"\#(start)[sSrR]k_(?:live|test)_[A-Za-z0-9]{16,}"#, false, nil),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, false, nil),
        (#"github_pat_[A-Za-z0-9_]{20,}"#, false, nil),
        (#"\#(start)glpat-[A-Za-z0-9_\-]{20,}"#, false, nil),
        // Hugging Face：主体不含下划线，`hf_hub_download` 之类的标识符不会被当成 token。
        (#"\#(start)hf_[A-Za-z0-9]{30,}"#, false, nil),
        (#"\#(start)npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"#, false, nil),
        (#"AKIA[0-9A-Z]{16}"#, false, nil),
        // AWS Secret Access Key 没有固定前缀，单独出现时与普通的 40 位 base64 无法区分，只在跟着键名时替换值。
        (#"((?:aws_?)?secret_?access_?key|aws_?secret_?key)(["']?\s*[:=]\s*["']?)[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])"#, true, "$1$2" + placeholderTemplate),
        (#"xox[abprs]-[A-Za-z0-9\-]{10,}"#, false, nil),
        // Slack Incoming Webhook：URL 本身就是凭据。
        (#"hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]{16,}"#, false, nil),
        (#"AIza[0-9A-Za-z_\-]{35}"#, false, nil),
        (#"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, false, nil),
        // 连接串里的密码 `scheme://user:password@host`：只换密码，用户名与主机保留（判断连的是哪里仍有用）。
        (#"(\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:)[^\s/@]+(@)"#, false, "$1" + placeholderTemplate + "$2"),
    ].compactMap { (pattern: String, caseInsensitive: Bool, template: String?) -> Rule? in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            assertionFailure("invalid redaction pattern: \(pattern)")
            return nil
        }
        return Rule(regex: regex, template: template ?? placeholderTemplate)
    }

    private static let cardCandidate = try! NSRegularExpression(pattern: #"\b(?:\d[ \-]?){13,19}\b"#)

    /// 返回脱敏后的文本与替换次数。
    public static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            let matches = rule.regex.numberOfMatches(in: result, range: range)
            if matches > 0 {
                result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
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
