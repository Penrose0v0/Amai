import Foundation
import Testing
@testable import AmaiCore

@Suite("SecretRedactor")
struct SecretRedactorTests {
    @Test("redacts common credential formats")
    func credentials() {
        let samples = [
            "key sk-ant-api03-abcdefghijklmnopqrstuv",
            "token ghp_abcdefghijklmnopqrstuvwxyz0123",
            "AKIAABCDEFGHIJKLMNOP",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "-----BEGIN RSA PRIVATE KEY-----",
        ]
        for sample in samples {
            let (text, count) = SecretRedactor.redact(sample)
            #expect(count == 1, "\(sample)")
            #expect(text.contains(SecretRedactor.placeholder))
        }
    }

    @Test("redacts Luhn-valid card numbers only")
    func cards() {
        #expect(SecretRedactor.redact("卡号 4111 1111 1111 1111").count == 1)
        #expect(SecretRedactor.redact("订单号 1234 5678 9012 3456").count == 0)
    }

    /// 回归：iOS PoC 里 OCR 把 `sk-ant-…` 认成 `Sk-ant-…` 并丢了末尾几个字符，密钥前半段漏进了观察与 daily。
    @Test("tolerates OCR case flips, truncation and look-alike characters")
    func ocrVariants() {
        let samples = [
            "API_KEY=Sk-ant-abcdefghijkmnpqrstuv",
            "SK-ANT-API03-ABCDEFGHIJKLMNOPQRSTUV",
            "key: sk–ant–api03–abcdefghijklmnopqrstuv",
            "key: sk—ant-api03-abcdefghijklmnopqrstuv",
            "5k-ant-api03-abcdefghijklmnopqrstuv",
            "export OPENAI_KEY=Sk-proj-abcdefghijklmnopqrstuvwxyz0123",
            "token Ghp_abcdefghijklmnopqrstuvwxyz0123",
            "AKlAABCDEFGHIJKLMNOP",
            "AK1AABCDEFGHIJKLMNOP",
            "Alza" + String(repeating: "Ab1_", count: 9) + "x",
            "Xoxb-1234567890-abcdefghij",
            "-----begin openssh private key-----",
        ]
        for sample in samples {
            let (text, count) = SecretRedactor.redact(sample)
            #expect(count == 1, "\(sample) → \(text)")
            #expect(text.contains(SecretRedactor.placeholder), "\(sample)")
        }
    }

    @Test("the synthetic PoC key leaves no prefix behind, however OCR capitalizes it")
    func pocKeyLeavesNoTrace() {
        let key = "sk-ant-" + "abcdefghijkmnpqrstuvwxyz"
        for ocr in [key, "S" + key.dropFirst(), "S" + key.dropFirst().dropLast(4), key.uppercased()] {
            let text = SecretRedactor.redact("API_KEY=\(ocr)\nREGION=ap-northeast-1").text
            #expect(!text.lowercased().contains(key.prefix(16)), "\(ocr) → \(text)")
            #expect(text.contains("REGION=ap-northeast-1"))
        }
    }

    @Test("look-alike prefixes inside ordinary words are not redacted")
    func noOverRedaction() {
        let texts = [
            "desk-organization-tools-list-2026",
            "task-ant-colony-simulation-v2-final",
            "5k-race-results-2026-spring-edition",
            "pip install scikit-learn; Sk-learn tutorial",
            "Ask-anything-about-the-project-roadmap",
            "skeleton-loading-placeholder-component",
            "AKIRA KUROSAWA RETROSPECTIVE 2026",
            "Alzheimer research summary for the 2026 review meeting",
            "the ghp mirror is at gh-pages_branch",
            "Xcode 中打开 sk-ant 文档，第 3 节",
        ]
        for text in texts {
            #expect(SecretRedactor.redact(text) == (text, 0), "\(text)")
        }
    }

    /// 回归：`sk-` 规则找数字的前瞻、连接串规则的 scheme 原来都没有上界，`sk-` 大量重复或很长的连字符文本时
    /// 耗时随长度平方增长（48 KB 约 6 秒）。每个输入约 100 KB。
    @Test("redaction stays linear on adversarial input", arguments: [
        ("sk- × 32k", String(repeating: "sk-", count: 32_000)),
        ("one long run", "sk-" + String(repeating: "a", count: 100_000)),
        ("many short candidates", String(repeating: "sk-abcdefghij", count: 8_000)),
        ("hyphenated, digit at the very end", String(repeating: "sk-abcdefghij-", count: 7_000) + "9"),
        ("OCR dashes", String(repeating: "Sk–", count: 32_000)),
        ("long hyphenated prose", String(repeating: "lorem-", count: 17_000)),
        ("dotted run", String(repeating: "a.", count: 50_000)),
        ("plus run", String(repeating: "x+", count: 50_000)),
    ])
    func redactionIsLinear(_ name: String, _ text: String) {
        let start = Date()
        _ = SecretRedactor.redact(text)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.5, "\(name): \(text.count) characters took \(elapsed)s")
    }

    @Test("a digit-free run stays unredacted however long it is")
    func longDigitFreeRun() {
        for text in [String(repeating: "sk-", count: 2_000), "sk-" + String(repeating: "word-", count: 400)] {
            #expect(SecretRedactor.redact(text).count == 0)
        }
    }

    /// 有界前瞻不能漏掉真实长度的密钥：数字只出现在主体末尾也要整条替换，OCR 改了首字母大小写同样如此。
    @Test("real-length sk- keys whose only digit is at the end are still fully redacted")
    func boundedWindowKeepsDetection() {
        let letters = String(repeating: "abcdefghijkmnpqrstuvwxyz", count: 12)
        let bodies = [
            "proj-" + String(letters.prefix(155)) + "7",   // sk-proj-：主体约 156 个字符
            "svcacct-" + String(letters.prefix(150)) + "3",
            String(letters.prefix(SecretRedactor.skDigitWindow)) + "1",  // 数字正好在窗口边界上
        ]
        for body in bodies {
            for prefix in ["sk-", "Sk-", "sk–"] {
                let (text, count) = SecretRedactor.redact("OPENAI_API_KEY=\(prefix)\(body)\nREGION=ap-northeast-1")
                #expect(count == 1, "\(prefix)\(body.prefix(12))…")
                #expect(!text.contains(body.prefix(20)), "\(prefix)\(body.prefix(12))…")
                #expect(text.contains("REGION=ap-northeast-1"))
            }
        }
    }

    /// OCR 把一长串连字符单词和后面的密钥连成一段时，后面的密钥仍从它自己的 `sk-` 处被找到。
    @Test("a key after a long digit-free hyphenated run is still redacted")
    func keyAfterLongRun() {
        let key = "sk-proj-" + String(repeating: "abcdefgh", count: 6) + "42xyz"
        let run = "sk-" + String(repeating: "lorem-", count: 60) + key
        let (text, count) = SecretRedactor.redact(run)
        #expect(count >= 1)
        #expect(!text.contains("abcdefghabcdefgh"), "\(text)")
    }

    /// 文档化的边界：数字只出现在主体前 `skDigitWindow` 个字符之外时不算密钥（真实密钥没有这么长的无数字前缀）。
    @Test("a digit only beyond the window does not make a key")
    func digitBeyondWindow() {
        let text = "sk-" + String(repeating: "a", count: SecretRedactor.skDigitWindow + 1) + "1"
        #expect(SecretRedactor.redact(text).count == 0)
    }

    /// 有界的 scheme 不能漏掉常见连接串；最长允许的 scheme 也要识别。
    @Test("connection-string passwords are still removed with the bounded scheme")
    func boundedScheme() {
        let longest = "x" + String(repeating: "y", count: SecretRedactor.schemeMaxLength - 1)
        for scheme in ["postgres", "postgresql", "mongodb+srv", "rediss", "amqps", "x-custom.v2+tls", longest] {
            let (text, count) = SecretRedactor.redact("DATABASE_URL=\(scheme)://admin:hunter2pass@db.example.test:5432/app")
            #expect(count == 1, "\(scheme)")
            #expect(!text.contains("hunter2pass") && text.contains("\(scheme)://admin:") && text.contains("@db.example.test"), "\(scheme)")
        }
    }

    @Test("leaves ordinary text alone")
    func ordinary() {
        let text = "在 Xcode 中编辑 ScreenFrameSource.swift，第 120 行"
        #expect(SecretRedactor.redact(text) == (text, 0))
    }
}
