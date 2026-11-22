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

    @Test("leaves ordinary text alone")
    func ordinary() {
        let text = "在 Xcode 中编辑 ScreenFrameSource.swift，第 120 行"
        #expect(SecretRedactor.redact(text) == (text, 0))
    }
}
