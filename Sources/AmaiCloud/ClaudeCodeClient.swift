import Foundation

// 用用户本机已登录的 Claude Code CLI（`claude -p`）调用 Claude 订阅模型（ADR-0005）。
// Amai 只启动用户自己安装、未修改的程序，不读取、不保存、不转发任何账户凭据。

// MARK: - Process running

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
}

/// 子进程执行的抽象，测试中替换为假实现。
public protocol ProcessRunning: Sendable {
    func run(
        executable: URL, arguments: [String], environment: [String: String],
        workingDirectory: URL, stdin: Data, timeout: TimeInterval
    ) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: URL, arguments: [String], environment: [String: String],
        workingDirectory: URL, stdin: Data, timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            // 边读边收，避免输出较大时管道写满导致子进程阻塞。
            let collector = OutputCollector()
            outPipe.fileHandleForReading.readabilityHandler = { collector.appendOut($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { collector.appendErr($0.availableData) }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                collector.markTimedOut()
                process.terminate()
            }

            process.terminationHandler = { p in
                timer.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: collector.result(status: p.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                continuation.resume(throwing: CloudError.toolNotFound(executable.path))
                return
            }
            timer.resume()
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    func appendOut(_ d: Data) { lock.withLock { out.append(d) } }
    func appendErr(_ d: Data) { lock.withLock { err.append(d) } }
    func markTimedOut() { lock.withLock { timedOut = true } }
    func result(status: Int32) -> ProcessResult {
        lock.withLock { ProcessResult(status: status, stdout: out, stderr: err, timedOut: timedOut) }
    }
}

// MARK: - Locating the CLI

public enum ClaudeCodeLocator {
    /// 常见安装位置。App 从 Finder 启动时 PATH 只有系统目录，因此直接查找文件。
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var list = [
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            // 版本号新的优先。
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                list.append(nvm.appendingPathComponent(v).appendingPathComponent("bin/claude"))
            }
        }
        return list
    }

    /// 设置中指定的路径优先；否则返回第一个存在且可执行的候选。
    public static func locate(configured: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fm = FileManager.default
        if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        return candidates(home: home).first { fm.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Status

public struct ClaudeCodeStatus: Sendable, Equatable {
    public let executable: URL
    public let version: String
    public let loggedIn: Bool
    /// 例如 `claude.ai`、`api_key`。只有 `claude.ai` 才使用订阅额度。
    public let authMethod: String?
    /// 例如 `pro`、`max`。
    public let subscriptionType: String?

    public var usesSubscription: Bool { loggedIn && authMethod == "claude.ai" }
}

// MARK: - Client

public struct ClaudeCodeClient: CloudTextClient {
    public static let modelAliases = ["opus", "sonnet", "haiku"]
    public static let defaultModel = "opus"

    public let executable: URL
    public let model: String
    public let workingDirectory: URL
    public let runner: any ProcessRunning
    public let timeout: TimeInterval

    public var identifier: String { "claude-code:\(model)" }

    public init(
        executable: URL,
        model: String = ClaudeCodeClient.defaultModel,
        workingDirectory: URL,
        runner: any ProcessRunning = SystemProcessRunner(),
        timeout: TimeInterval = 300
    ) {
        self.executable = executable
        self.model = model
        self.workingDirectory = workingDirectory
        self.runner = runner
        self.timeout = timeout
    }

    /// 子进程环境：只保留基本变量。刻意不传 `ANTHROPIC_API_KEY` 等变量——
    /// `-p` 模式下只要有 API Key 就会改用 API 计费，而不是订阅额度。
    static func environment(from parent: [String: String] = ProcessInfo.processInfo.environment, executable: URL) -> [String: String] {
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = parent[key] { env[key] = value }
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["PATH"] = "\(executable.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// 关闭工具、不加载用户全局设置 / 钩子 / MCP / 技能，只生成文字。
    func arguments(for request: CloudRequest) -> [String] {
        var args = [
            "-p",
            "--output-format", "json",
            "--model", model,
            "--system-prompt", request.system,
            "--tools", "",
            "--no-session-persistence",
            "--setting-sources", "project",
            "--strict-mcp-config",
            "--disable-slash-commands",
        ]
        if let schema = request.schemaJSON {
            args += ["--json-schema", schema]
        }
        return args
    }

    public func generate(_ request: CloudRequest) async throws -> CloudResponse {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw CloudError.missingModel(.anthropic) }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let result = try await runner.run(
            executable: executable,
            arguments: arguments(for: request),
            environment: Self.environment(executable: executable),
            workingDirectory: workingDirectory,
            stdin: Data(request.user.utf8),
            timeout: timeout
        )
        if result.timedOut { throw CloudError.network("Claude Code 超过 \(Int(timeout)) 秒未返回") }
        return try Self.parse(result, model: model)
    }

    static func parse(_ result: ProcessResult, model: String) throws -> CloudResponse {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        // 输出的最后一个 JSON 对象行是结果；前面可能有诊断行。
        let line = stdout.split(separator: "\n").last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let line, let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw classify(message: stderr.isEmpty ? stdout : stderr, fallback: .local("Claude Code 退出码 \(result.status)"))
        }
        let resultText = obj["result"] as? String ?? ""
        if obj["is_error"] as? Bool == true {
            throw classify(message: resultText + "\n" + stderr, fallback: .badRequest(String(resultText.prefix(200))))
        }
        let text: String
        if let structured = obj["structured_output"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            text = String(decoding: data, as: UTF8.self)
        } else if !resultText.isEmpty {
            text = resultText
        } else {
            throw CloudError.invalidResponse
        }
        var input = 0, output = 0
        var usedModel = model
        if let usage = obj["modelUsage"] as? [String: [String: Any]], let first = usage.first {
            usedModel = first.key
            input = (first.value["inputTokens"] as? Int ?? 0) + (first.value["cacheCreationInputTokens"] as? Int ?? 0)
                + (first.value["cacheReadInputTokens"] as? Int ?? 0)
            output = first.value["outputTokens"] as? Int ?? 0
        }
        return CloudResponse(text: text, model: usedModel, inputTokens: input, outputTokens: output)
    }

    /// 根据错误文字归类；只保留简短片段，不包含请求内容。
    static func classify(message: String, fallback: CloudError) -> CloudError {
        let m = message.lowercased()
        let snippet = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        if m.contains("not logged in") || m.contains("/login") || m.contains("invalid api key") || m.contains("oauth token") {
            return .signInRequired("请在终端运行 claude 并执行 /login")
        }
        if m.contains("usage limit") || m.contains("limit reached") || m.contains("rate limit") || m.contains("out of extra usage") {
            return .planUsageLimit(snippet)
        }
        if m.contains("unrecognized_model") || m.contains("model not found") || m.contains("invalid model") {
            return .badRequest("模型不可用：\(snippet)")
        }
        return fallback
    }

    // MARK: Status check

    /// 运行 `claude --version` 与 `claude auth status`，只读取其输出中的登录状态，不接触凭据本身。
    public static func status(executable: URL, runner: any ProcessRunning = SystemProcessRunner(), workingDirectory: URL) async throws -> ClaudeCodeStatus {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let env = environment(executable: executable)
        let versionResult = try await runner.run(
            executable: executable, arguments: ["--version"], environment: env,
            workingDirectory: workingDirectory, stdin: Data(), timeout: 20
        )
        let version = String(decoding: versionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let authResult = try await runner.run(
            executable: executable, arguments: ["auth", "status"], environment: env,
            workingDirectory: workingDirectory, stdin: Data(), timeout: 20
        )
        let obj = (try? JSONSerialization.jsonObject(with: authResult.stdout)) as? [String: Any] ?? [:]
        return ClaudeCodeStatus(
            executable: executable,
            version: version,
            loggedIn: obj["loggedIn"] as? Bool ?? false,
            authMethod: obj["authMethod"] as? String,
            subscriptionType: obj["subscriptionType"] as? String
        )
    }
}
