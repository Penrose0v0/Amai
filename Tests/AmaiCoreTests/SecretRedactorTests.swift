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

    @Test("leaves ordinary text alone")
    func ordinary() {
        let text = "在 Xcode 中编辑 ScreenFrameSource.swift，第 120 行"
        #expect(SecretRedactor.redact(text) == (text, 0))
    }
}
