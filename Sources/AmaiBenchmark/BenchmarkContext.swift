import AmaiCore
import AmaiExtraction
import AmaiMemory
import Foundation

/// 本次运行使用的模型。nil 表示不使用（依赖它的部分记为跳过）。全部是本机 MLX 模型：
/// Benchmark 不把任何数据发往外部服务。
public struct BenchmarkModels: Sendable {
    /// 抽取用的视觉模型（端到端）。
    public var vision: String?
    /// 记忆整理用的文本模型。
    public var memory: String?
    /// 助手作答模型。
    public var answer: String?
    /// 独立 Judge（与作答模型不同家族）。
    public var judge: String?
    /// 向量模型；nil 时检索只用关键词。
    public var embedder: String?

    public init(vision: String? = nil, memory: String? = nil, answer: String? = nil, judge: String? = nil, embedder: String? = nil) {
        self.vision = vision
        self.memory = memory
        self.answer = answer
        self.judge = judge
        self.embedder = embedder
    }

    public static let none = BenchmarkModels()

    /// 只保留本机已下载的模型；返回缺失的模型，供报告说明。
    public func installedOnly() -> (models: BenchmarkModels, missing: [String]) {
        var m = self
        var missing: [String] = []
        func check(_ keyPath: WritableKeyPath<BenchmarkModels, String?>) {
            if let tag = m[keyPath: keyPath], !LocalInferenceBackend.isInstalled(tag: tag) {
                missing.append(tag)
                m[keyPath: keyPath] = nil
            }
        }
        check(\.vision)
        check(\.memory)
        check(\.answer)
        check(\.judge)
        check(\.embedder)
        return (m, missing)
    }

    public var description: [String: String] {
        var d: [String: String] = [:]
        d["vision"] = vision ?? "none"
        d["memory"] = memory ?? "none"
        d["answer"] = answer ?? "none"
        d["judge"] = judge ?? "none"
        d["embedder"] = embedder ?? "none"
        return d
    }
}

public struct BenchmarkContext: Sendable {
    public var fixtures: URL
    /// 本次运行的目录；明细写在其下的 details/。
    public var runDirectory: URL
    public var models: BenchmarkModels
    /// 真实记忆问答评测的工作目录（docs/qa-eval.md）：只读取其中的汇总计数。
    public var qaWorkdir: URL?
    public var log: @Sendable (String) -> Void
    let scratchRoot: URL

    public init(fixtures: URL, runDirectory: URL, models: BenchmarkModels, qaWorkdir: URL?, log: @escaping @Sendable (String) -> Void) {
        self.fixtures = fixtures
        self.runDirectory = runDirectory
        self.models = models
        self.qaWorkdir = qaWorkdir
        self.log = log
        scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("amai-bench-\(UUID().uuidString)", isDirectory: true)
    }

    public func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    public func dataset(_ name: String, _ url: URL, origin: DataOrigin = .synthetic) -> DatasetRef {
        let path = url.path.replacingOccurrences(of: FileManager.default.currentDirectoryPath + "/", with: "")
        return DatasetRef(name: name, path: path, sha256: TextMetrics.sha256(file: url), origin: origin)
    }

    /// 临时目录（系统临时目录下，运行结束删除）。
    public func scratch(_ name: String) -> URL {
        let url = scratchRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func cleanup() { try? FileManager.default.removeItem(at: scratchRoot) }

    public var detailsDirectory: URL { runDirectory.appendingPathComponent("details", isDirectory: true) }

    public func writeDetail<T: Encodable>(_ name: String, _ value: T) throws {
        try FileManager.default.createDirectory(at: detailsDirectory, withIntermediateDirectories: true)
        try BenchmarkFiles.encoder().encode(value).write(to: detailsDirectory.appendingPathComponent(name))
    }

    public func writeDetail(_ name: String, text: String) throws {
        try FileManager.default.createDirectory(at: detailsDirectory, withIntermediateDirectories: true)
        try text.write(to: detailsDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

public enum BenchmarkFiles {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func lines<T: Encodable>(_ values: [T]) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try values.map { String(decoding: try e.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }
}

/// 本地文本模型适配为记忆层的模型接口（与 App 的 LocalLanguageModel、amai-memory eval 的 EvalLocalModel 相同）。
struct BenchmarkMemoryModel: MemoryLanguageModel {
    let provider: MLXModelProvider
    var identifier: String { provider.identifier }

    func complete(system: String, user: String, maxTokens: Int, schema: OutputSchema?) async throws -> String {
        try await provider.generate(ModelRequest(cacheable: system, dynamic: user, maxTokens: maxTokens)).text
    }
}
