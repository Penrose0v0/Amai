import AmaiCore
import AmaiMemory
import Foundation
import MCP

/// 只读 MCP Server（ADR-0008）：把 `MemoryAPI` 暴露为三个 Tools。
///
/// - 每次调用都重新读取 `config.json`：`mcp.enabled` 为 false、配置缺失或无效时一律拒绝（fail closed），
///   用户改配置后立即生效，不需要重启客户端；
/// - 检索用本进程内存中的 `MemoryIndex`，从 Markdown 原文增量构建，不读写 App 的索引数据库；
/// - 只读，不联网；日志不记录查询与记忆内容。
public actor AmaiMCPServer {
    public static let name = "amai"
    /// 随 App 打包时 `Bundle.main` 就是 Amai.app，版本与 App 一致；开发时直接运行构建产物则为 "dev"。
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private let configURL: URL
    private var index: (root: URL, index: MemoryIndex)?
    private let log = AmaiLog.logger("mcp")

    public init(configURL: URL) {
        self.configURL = configURL
    }

    /// 配置文件中与 MCP 有关的部分。其余配置由 App 管理，这里不解析。
    struct Settings: Decodable {
        var memory: MemoryConfiguration?
        var mcp: MCPConfiguration?
    }

    enum Unavailable: Error, CustomStringConvertible {
        case disabled
        case unreadableConfig

        var description: String {
            switch self {
            case .disabled:
                "Amai memory access over MCP is turned off. The user can enable it by setting \"mcp\": {\"enabled\": true} in Amai's config.json."
            case .unreadableConfig:
                "Amai's config.json is missing or invalid, so memory access over MCP is turned off."
            }
        }
    }

    // MARK: - MCP

    public func makeServer() -> Server {
        Server(
            name: Self.name,
            version: Self.version,
            title: "Amai Memory",
            instructions: """
            Read-only access to the user's Amai memory: long-term memory categories, a searchable history and daily activity timelines.
            Timeline entries and most memory entries are inferred by a model from screen activity; `kind` tells whether an entry was observed, stated by the user, inferred or confirmed. Treat inferred entries as uncertain.
            Only the categories the user enabled are available.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    public func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }
        // Server 持有处理函数、处理函数持有本对象；本对象不持有 Server，没有循环引用。
        await server.withMethodHandler(CallTool.self) { params in
            await self.call(params)
        }
    }

    static let tools: [Tool] = [
        Tool(
            name: "search_memory",
            title: "Search memory",
            description: "Full-text search across the user's enabled Amai memory (long-term categories and, if enabled, daily records). Returns matching entries with category, section, content, date, source dates and evidence kind.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string", "description": "Words or a phrase to search for. Matches substrings, including Chinese and Japanese text."]),
                    "limit": .object(["type": "integer", "minimum": 1, "maximum": .int(MemoryAPI.maxSearchLimit), "default": 10]),
                ]),
                "required": .array(["query"]),
            ]),
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_timeline",
            title: "Get daily timeline",
            description: "The user's activity timeline for one day (time ranges, titles, summaries, confidence) and the end-of-day summary if it exists. Requires the daily category to be enabled.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "date": .object(["type": "string", "description": "YYYY-MM-DD in the user's local time zone, or today / yesterday."]),
                ]),
                "required": .array(["date"]),
            ]),
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_memory",
            title: "Get long-term memory",
            description: "Read one long-term memory category: entries grouped by section, with source dates and evidence kind, plus the user's own notes. Pass topic to read a single section (for example a project name or Plans); the response lists available topics.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "category": .object([
                        "type": "string",
                        "enum": .array(MemoryCategory.documents.map { .string($0.rawValue) }),
                    ]),
                    "topic": .object(["type": "string", "description": "Optional section name within the category."]),
                ]),
                "required": .array(["category"]),
            ]),
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
    ]

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            let api = try currentAPI()
            switch params.name {
            case "search_memory":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return Self.failure("query is required")
                }
                let limit = args["limit"]?.intValue ?? Int(args["limit"]?.doubleValue ?? 10)
                return try Self.success(["results": try await api.search(query, limit: limit)])
            case "get_timeline":
                guard let date = args["date"]?.stringValue else { return Self.failure("date is required") }
                return try Self.success(try api.timeline(on: date))
            case "get_memory":
                guard let name = args["category"]?.stringValue, let category = MemoryCategory(rawValue: name), category != .daily else {
                    return Self.failure("category must be one of: \(MemoryCategory.documents.map(\.rawValue).joined(separator: ", "))")
                }
                guard let memory = try api.memory(category, topic: args["topic"]?.stringValue) else {
                    return Self.failure("\(category.rawValue).md does not exist yet")
                }
                return try Self.success(memory)
            default:
                return Self.failure("Unknown tool \(params.name)")
            }
        } catch let error as Unavailable {
            return Self.failure(error.description)
        } catch let error as MemoryAPIError {
            return Self.failure(error.description)
        } catch {
            log.error("tool \(params.name, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
            return Self.failure("Amai could not read its memory: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// 按当前配置构建 API；记忆目录变了就换一个新的内存索引。
    private func currentAPI() throws -> MemoryAPI {
        guard let data = try? Data(contentsOf: configURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { throw Unavailable.unreadableConfig }
        let mcp = settings.mcp ?? .default
        guard mcp.enabled else { throw Unavailable.disabled }
        let root = (settings.memory ?? .default).rootURL
        if index?.root != root {
            index = (root, MemoryIndex(root: root, database: try MemoryIndexDatabase.inMemory()))
        }
        return MemoryAPI(root: root, index: index?.index, access: mcp.access)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func success(_ value: some Encodable) throws -> CallTool.Result {
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
    }

    static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
