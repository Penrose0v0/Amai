import Foundation
import Testing
@testable import AmaiCore

/// 脱敏的漏检、误脱敏与边界行为。样本全部是合成的（形态与真实凭据一致，但不是有效凭据）。
///
/// `withKnownIssue` 标出的是已确认、尚未修复的问题（误脱敏的取舍、OCR 折行、性能）：测试保持通过，
/// 修复后会提示"已知问题未出现"，那时去掉 `withKnownIssue` 即成为普通的回归测试。
@Suite("SecretRedactor coverage")
struct RedactionCoverageTests {
    // MARK: - 已覆盖行为的回归保护

    @Test("redaction is idempotent and the placeholder never matches a rule")
    func idempotent() {
        let text = """
        ANTHROPIC=sk-ant-api03-abcdefghijklmnopqrstuv
        GITHUB=ghp_abcdefghijklmnopqrstuvwxyz0123
        card 4111 1111 1111 1111
        """
        let once = SecretRedactor.redact(text)
        let twice = SecretRedactor.redact(once.text)
        #expect(once.count == 3)
        #expect(twice.text == once.text && twice.count == 0)
        #expect(SecretRedactor.redact(SecretRedactor.placeholder).count == 0)
    }

    @Test("every credential in a multi-secret screen is removed, surrounding text kept")
    func multipleSecretsOneScreen() {
        let text = """
        # .env
        OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123
        AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP
        SLACK=xoxb-1234567890-abcdefghij
        GOOGLE=AIza\(String(repeating: "Ab1_", count: 9))x
        JWT=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
        PORT=8080
        """
        let (out, count) = SecretRedactor.redact(text)
        #expect(count == 5, "\(out)")
        for leaked in ["sk-proj-abc", "AKIAABCD", "xoxb-123", "AIzaAb1", "eyJhbGci"] {
            #expect(!out.contains(leaked), "\(leaked) leaked: \(out)")
        }
        #expect(out.contains("PORT=8080") && out.contains("# .env"))
    }

    // MARK: - 漏检（已修复，回归保护）

    /// 回归：曾只替换 `-----BEGIN … PRIVATE KEY-----` 这一行，密钥正文（base64）原样保留。
    @Test("a PEM private key body is removed, not just its header line")
    func pemBody() {
        let key = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun
        VTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u+qKhbwKfBstIs+bMY2Zkp18gnTxK
        -----END RSA PRIVATE KEY-----
        """
        let out = SecretRedactor.redact(key).text
        #expect(!out.contains("MIIEowIBAAKCAQEA"), "\(out)")
        #expect(!out.contains("VTLw7onLRnrq0"), "\(out)")
    }

    /// 回归：AWS 的访问密钥 ID（AKIA…）会被替换，与它成对出现、真正有权限的 Secret Access Key 曾不会。
    /// Secret 没有固定前缀，只在跟着键名时替换，键名保留。
    @Test("an AWS secret access key next to its key id is removed")
    func awsSecretAccessKey() {
        let text = """
        aws_access_key_id = AKIAABCDEFGHIJKLMNOP
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
        """
        let out = SecretRedactor.redact(text).text
        #expect(!out.contains("AKIAABCD"))
        #expect(!out.contains("wJalrXUtnFEMI"), "\(out)")
        #expect(out.contains("aws_secret_access_key = [已脱敏]"), "\(out)")
    }

    /// 回归：与已覆盖的格式一样"形态明确"（固定前缀 + 长随机主体），曾没有规则。
    /// 其中 Hugging Face token 与本项目直接相关：下载模型权重的环境里常会出现。
    /// 样本是虚构的，但形态与真实凭据一致；拆成两段拼接，避免仓库的密钥扫描把它们当成泄露的凭据。
    @Test("well-formed tokens with fixed prefixes are removed",
          arguments: [
              "STRIPE_SECRET=sk_" + "live_51HqLyjWDarjtT1zdp7dcXyZabcdefGHIJ",
              "STRIPE_RESTRICTED=rk_" + "live_51HqLyjWDarjtT1zdp7dcXyZabcdefGHIJ",
              "HF_TOKEN=hf_aBcDeFgHiJkLmNoPqRsTuVwXyZ01234567",
              "GITLAB=glpat-aBcDeFgHiJkLmNoPqRsT",
              "//registry.npmjs.org/:_authToken=npm_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
              "https://hooks.slack.com" + "/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX",
          ])
    func fixedPrefixTokens(_ sample: String) {
        #expect(SecretRedactor.redact(sample).count >= 1, "\(sample)")
    }

    /// 回归：连接串里的密码（`scheme://user:password@host`）。只换密码，用户名与主机保留。
    @Test("passwords embedded in connection URLs are removed")
    func urlCredentials() {
        let out = SecretRedactor.redact("DATABASE_URL=postgres://admin:S3cr3tP4ssw0rd@db.example.com:5432/app").text
        #expect(!out.contains("S3cr3tP4ssw0rd"), "\(out)")

        #expect(out == "DATABASE_URL=postgres://admin:[已脱敏]@db.example.com:5432/app", "\(out)")
    }

    /// OCR 按屏幕宽度折行时，长密钥被拆成两行：第一行被替换，第二行（密钥后半段）留下。
    @Test("a key wrapped across two OCR lines leaves nothing behind")
    func wrappedKey() {
        let out = SecretRedactor.redact("sk-ant-api03-abcdefghij\nklmnopqrstuvwxyz0123").text
        #expect(out.hasPrefix(SecretRedactor.placeholder))
        withKnownIssue("the continuation line of a wrapped key is kept") {
            #expect(!out.contains("klmnopqrstuvwxyz0123"), "\(out)")
        }
    }

    /// 新增规则的误伤边界：形似但不是凭据的文字保持原样。
    @Test("look-alikes of the newer token formats are kept")
    func newRulesNoOverRedaction() {
        let texts = [
            "from huggingface_hub import hf_hub_download",
            "npm_config_registry=https://registry.npmjs.org/",
            "ssh://git@github.com/owner/repo.git",
            "https://user@example.com/path",
            "secret_access_key = <set me>",
            "sk_live mode is enabled for the dashboard",
            "-----END RSA PRIVATE KEY-----",
            "glpat- prefix is documented in the GitLab manual",
        ]
        for text in texts {
            #expect(SecretRedactor.redact(text) == (text, 0), "\(text) → \(SecretRedactor.redact(text).text)")
        }
        // 私钥块之后的普通文字不被吞掉。
        let key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\nnext line stays"
        #expect(SecretRedactor.redact(key) == ("\(SecretRedactor.placeholder)\nnext line stays", 1))
    }

    // MARK: - 误脱敏（已确认）

    /// 卡号规则只看"13–19 位数字 + Luhn"。随机数字串约 1/10 能通过 Luhn，于是 13 位的毫秒时间戳、
    /// 带国家码的手机号、订单号里约一成会被替换成占位符（实测：毫秒时间戳 12%，+86 手机号 10%）。
    @Test("13-digit millisecond timestamps are not treated as card numbers")
    func timestampsAreNotCards() {
        let redacted = (0..<1000).map { 1_732_252_800_000 + Int64($0) * 997 }
            .filter { SecretRedactor.redact("created_at \($0)").count > 0 }
        withKnownIssue("Luhn-only card detection hits ~10% of 13-digit numbers") {
            #expect(redacted.isEmpty, "\(redacted.count)/1000 redacted, e.g. \(redacted.prefix(3))")
        }
    }

    @Test("phone numbers with a country code are not treated as card numbers")
    func phonesAreNotCards() {
        let redacted = (0..<1000).map { "+86 13\(String(format: "%09d", $0 * 7919 % 1_000_000_000))" }
            .filter { SecretRedactor.redact("电话 \($0)").count > 0 }
        withKnownIssue("Luhn-only card detection hits ~10% of 13-digit phone numbers") {
            #expect(redacted.isEmpty, "\(redacted.count)/1000 redacted, e.g. \(redacted.prefix(3))")
        }
    }

    /// `sk-` 规则只要求"主体里有一个数字且长度 ≥20"，以 `sk-` 开头的长 kebab-case 名称会被整段替换。
    @Test("long kebab-case names starting with sk- are kept")
    func kebabSlug() {
        let slug = "sk-learn-2026-tutorial-part-12-advanced-topics"
        withKnownIssue("sk- rule matches kebab-case slugs that contain a digit") {
            #expect(SecretRedactor.redact(slug).count == 0)
        }
    }

    // MARK: - 资源

    /// 性能保护：`sk-` 规则若用前瞻 `(?=body*[0-9])` 要求主体含数字（OCR 容错版本的写法），每个可能的起点都会扫到文本末尾，
    /// `sk-` 连续重复时耗时随长度平方增长（实测 24 KB 0.8 s，96 KB 12 s）。屏幕 OCR 通常只有几 KB，实际风险低；
    /// 整理提示词更长，也经过同一函数。没有这种前瞻的规则下本测试直接通过，所以标为 intermittent。
    @Test("redaction stays fast on adversarial input")
    func adversarialInputPerformance() {
        let text = String(repeating: "sk-", count: 16_000) // 48 KB
        let start = Date()
        _ = SecretRedactor.redact(text)
        let elapsed = Date().timeIntervalSince(start)
        withKnownIssue("quadratic backtracking in the sk- rule", isIntermittent: true) {
            #expect(elapsed < 0.5, "took \(elapsed)s")
        }
    }
}
