import AmaiMemory
import Foundation
import MCP
import System
import Testing
@testable import AmaiMCP

/// 用官方 SDK 的客户端走完整的 MCP 握手与调用。记忆目录与配置都是临时生成的合成数据。
@Suite("MCP server", .serialized)
struct AmaiMCPServerTests {
    struct Fixture {
        let dir: URL
        var config: URL { dir.appendingPathComponent("config.json") }
        var memory: URL { dir.appendingPathComponent("memory", isDirectory: true) }

        init(enabled: Bool, categories: [String]? = nil) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-mcp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: memory.appendingPathComponent("daily"), withIntermediateDirectories: true)
            try """
            # 工作

            <!-- amai:memory:begin · x -->
            ### Lumen
            - 离线同步队列已完成，等待联调 <!-- src:2026-10-19 kind:observed -->
            <!-- amai:memory:end -->
            """.write(to: memory.appendingPathComponent("work.md"), atomically: true, encoding: .utf8)
            try """
            # 财务

            <!-- amai:memory:begin · x -->
            ### 支出
            - 同步服务器月费 20 美元 <!-- src:2026-10-19 kind:stated -->
            <!-- amai:memory:end -->
            """.write(to: memory.appendingPathComponent("finance.md"), atomically: true, encoding: .utf8)
            try """
            # 2026-10-19

            ## 时间线

            <!-- amai:timeline:begin · x -->
            - 09:00–10:30 实现同步队列 <!-- seg:A conf:0.88 src:t -->
            <!-- amai:timeline:end -->
            """.write(to: memory.appendingPathComponent("daily/2026-10-19.md"), atomically: true, encoding: .utf8)
            try setConfig(enabled: enabled, categories: categories)
        }

        func setConfig(enabled: Bool, categories: [String]? = nil) throws {
            var mcp: [String: Any] = ["enabled": enabled]
            if let categories { mcp["categories"] = categories }
            let json: [String: Any] = ["memory": ["root": memory.path], "mcp": mcp]
            try JSONSerialization.data(withJSONObject: json).write(to: config)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func connect(_ f: Fixture) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let amai = AmaiMCPServer(configURL: f.config)
        let server = await amai.makeServer()
        await amai.register(on: server)
        try await server.start(transport: serverTransport)
        let client = Client(name: "amai-tests", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    private func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
    }

    @Test("lists three read-only tools")
    func listTools() async throws {
        let f = try Fixture(enabled: true)
        defer { f.cleanup() }
        let client = try await connect(f)
        let tools = try await client.listTools().tools
        #expect(tools.map(\.name) == ["search_memory", "get_timeline", "get_memory"])
        #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true && $0.annotations.openWorldHint == false })
    }

    @Test("default categories: work is readable, finance and daily are not")
    func defaultCategories() async throws {
        let f = try Fixture(enabled: true)
        defer { f.cleanup() }
        let client = try await connect(f)

        let search = try await client.callTool(name: "search_memory", arguments: ["query": "同步"])
        #expect(search.isError == false)
        let results = try JSONDecoder().decode([String: [MemorySearchResult]].self, from: Data(text(search.content).utf8))["results"] ?? []
        #expect(results.map(\.content) == ["离线同步队列已完成，等待联调"])
        #expect(results.first?.kind == .observed && results.first?.sources == ["2026-10-19"])

        let work = try await client.callTool(name: "get_memory", arguments: ["category": "work", "topic": "Lumen"])
        #expect(work.isError == false && text(work.content).contains("离线同步队列已完成"))

        let finance = try await client.callTool(name: "get_memory", arguments: ["category": "finance"])
        #expect(finance.isError == true && text(finance.content).contains("not enabled"))
        let timeline = try await client.callTool(name: "get_timeline", arguments: ["date": "2026-10-19"])
        #expect(timeline.isError == true && !text(timeline.content).contains("实现同步队列"))
    }

    @Test("disabled by default; turning it on or off takes effect on the next call")
    func enableSwitch() async throws {
        let f = try Fixture(enabled: false)
        defer { f.cleanup() }
        let client = try await connect(f)
        let off = try await client.callTool(name: "search_memory", arguments: ["query": "同步"])
        #expect(off.isError == true && text(off.content).contains("turned off"))
        #expect(!text(off.content).contains("离线"))

        try f.setConfig(enabled: true, categories: ["daily"])
        let on = try await client.callTool(name: "get_timeline", arguments: ["date": "2026-10-19"])
        #expect(on.isError == false && text(on.content).contains("实现同步队列"))

        try "{ not json".write(to: f.config, atomically: true, encoding: .utf8)
        let broken = try await client.callTool(name: "get_timeline", arguments: ["date": "2026-10-19"])
        #expect(broken.isError == true && !text(broken.content).contains("实现同步队列"))
    }

    /// 同一个 Server 实例（即同一个 amai-mcp 进程）期间记忆文件被新增、修改、删除，检索与读取都反映最新内容。
    @Test("search follows Markdown changes while the server keeps running")
    func refreshesAfterChanges() async throws {
        let f = try Fixture(enabled: true, categories: ["general", "work", "goals", "daily"])
        defer { f.cleanup() }
        let client = try await connect(f)
        func search(_ q: String) async throws -> [MemorySearchResult] {
            let r = try await client.callTool(name: "search_memory", arguments: ["query": .string(q)])
            #expect(r.isError == false)
            return try JSONDecoder().decode([String: [MemorySearchResult]].self, from: Data(text(r.content).utf8))["results"] ?? []
        }
        // 先检索一次，让进程内索引建立。
        #expect(try await search("论文").isEmpty)

        // 新增：goals.md 与新的一天。
        let goals = f.memory.appendingPathComponent("goals.md")
        try """
        # 目标

        <!-- amai:memory:begin · x -->
        ### 计划
        - 论文投 UIST <!-- src:2026-10-20 kind:stated -->
        <!-- amai:memory:end -->
        """.write(to: goals, atomically: true, encoding: .utf8)
        let newDay = f.memory.appendingPathComponent("daily/2026-10-20.md")
        try "# 2026-10-20\n\n## 笔记\n\n和导师讨论论文结构。\n".write(to: newDay, atomically: true, encoding: .utf8)
        let added = try await search("论文")
        #expect(added.contains { $0.category == .goals && $0.content == "论文投 UIST" && $0.sources == ["2026-10-20"] })
        #expect(added.contains { $0.category == .daily && $0.date == "2026-10-20" })

        // 修改：改写条目（长度不变也要识别），旧内容不再出现。
        try """
        # 目标

        <!-- amai:memory:begin · x -->
        ### 计划
        - 论文投 CHI2 <!-- src:2026-10-21 kind:stated -->
        <!-- amai:memory:end -->
        """.write(to: goals, atomically: true, encoding: .utf8)
        let modified = try await search("论文")
        #expect(modified.contains { $0.content == "论文投 CHI2" && $0.sources == ["2026-10-21"] })
        #expect(!modified.contains { $0.content == "论文投 UIST" })
        #expect(try await search("UIST").isEmpty)
        let plans = try await client.callTool(name: "get_memory", arguments: ["category": "goals", "topic": "计划"])
        #expect(text(plans.content).contains("论文投 CHI2") && !text(plans.content).contains("UIST"))

        // 删除：文件删掉后不再被检索到，读取也随之变化。
        try FileManager.default.removeItem(at: goals)
        try FileManager.default.removeItem(at: newDay)
        #expect(try await search("论文").isEmpty)
        let gone = try await client.callTool(name: "get_memory", arguments: ["category": "goals"])
        #expect(gone.isError == true)
        let day = try await client.callTool(name: "get_timeline", arguments: ["date": "2026-10-20"])
        #expect(text(day.content).contains("\"exists\" : false"))
    }

    @Test("bad arguments are reported as tool errors")
    func badArguments() async throws {
        let f = try Fixture(enabled: true)
        defer { f.cleanup() }
        let client = try await connect(f)
        #expect(try await client.callTool(name: "search_memory", arguments: [:]).isError == true)
        #expect(try await client.callTool(name: "get_memory", arguments: ["category": "daily"]).isError == true)
        #expect(try await client.callTool(name: "get_timeline", arguments: ["date": "yesterday-ish"]).isError == true)
        #expect(try await client.callTool(name: "write_memory", arguments: [:]).isError == true)
    }

    /// 端到端：以子进程启动构建出的 amai-mcp，经 stdio 通信（与 Claude Desktop、Atd 启动它的方式相同）。
    @Test("amai-mcp works over stdio as a subprocess")
    func stdioSubprocess() async throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/amai-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build amai-mcp first: swift build --product amai-mcp")
        let f = try Fixture(enabled: true, categories: ["work", "daily"])
        defer { f.cleanup() }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--config", f.config.path]
        let toServer = Pipe(), fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: "amai-tests", version: "1")
        let initialized = try await client.connect(transport: transport)
        #expect(initialized.serverInfo.name == "amai")
        #expect(try await client.listTools().tools.count == 3)
        let timeline = try await client.callTool(name: "get_timeline", arguments: ["date": "2026-10-19"])
        let day = try JSONDecoder().decode(DayTimeline.self, from: Data(text(timeline.content).utf8))
        #expect(day.entries.map(\.title) == ["实现同步队列"])
        await client.disconnect()
    }
}
