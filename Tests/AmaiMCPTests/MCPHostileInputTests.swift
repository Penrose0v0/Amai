import AmaiMemory
import Foundation
import MCP
import Testing
@testable import AmaiMCP

/// MCP 是外部 Agent 能直接调用的接口，参数完全不受 Amai 控制。这里只放现有测试没覆盖、
/// 而外部调用方实际可以构造的输入：越界的数值、分区之外的文件、路径形式的日期。
@Suite("MCP hostile input", .serialized)
struct MCPHostileInputTests {
    typealias Fixture = AmaiMCPServerTests.Fixture

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

    /// 用户自己在记忆目录里建的文件（不属于任何分区）和未授权分区的文件，都不能经检索泄露。
    @Test("files outside the enabled categories never appear in search results")
    func nonCategoryFilesStayPrivate() async throws {
        let f = try Fixture(enabled: true, categories: ["work", "daily"])
        defer { f.cleanup() }
        let marker = "zebrapassphrase"
        let notes = f.memory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# 私人\n\n- \(marker) 个人笔记\n".write(to: notes.appendingPathComponent("private.md"), atomically: true, encoding: .utf8)
        try "# 草稿\n\n- \(marker) 顶层草稿\n".write(to: f.memory.appendingPathComponent("drafts.md"), atomically: true, encoding: .utf8)
        try "# 健康\n\n- \(marker) 体检结果\n".write(to: f.memory.appendingPathComponent("health.md"), atomically: true, encoding: .utf8)

        let client = try await connect(f)
        let search = try await client.callTool(name: "search_memory", arguments: ["query": .string(marker), "limit": 50])
        #expect(search.isError == false)
        #expect(!text(search.content).contains(marker), "\(text(search.content))")
    }

    /// 日期参数最终会拼成 daily 下的文件路径；任何路径形式都必须被拒绝，而不是读到别的文件。
    @Test("path-like dates are rejected instead of reading other files")
    func pathLikeDates() async throws {
        let f = try Fixture(enabled: true, categories: ["work", "daily"])
        defer { f.cleanup() }
        let client = try await connect(f)
        for date in ["../work", "2026-10-19/../../work", "../../config", "2026-10-19.md", "2026-02-30", " 2026-10-19/.."] {
            let result = try await client.callTool(name: "get_timeline", arguments: ["date": .string(date)])
            #expect(result.isError == true, "\(date) → \(text(result.content))")
            #expect(!text(result.content).contains("离线同步队列"), "\(date)")
        }
        // FTS5 查询语法不应导致错误或绕过分区过滤。
        let fts = try await client.callTool(name: "search_memory", arguments: ["query": #"" OR * NEAR( ) AND 支出"#])
        #expect(fts.isError == false)
        #expect(!text(fts.content).contains("同步服务器月费"))
    }

    /// 回归：`limit` 为超出 Int 范围的 JSON 数字（1e300、2^63）时，`Int(Double)` 曾直接 trap，
    /// amai-mcp 进程崩溃（退出码 133）。现在夹到允许范围内照常检索。
    /// 崩溃无法在测试进程内复现（会带走整个测试进程），所以以子进程方式运行构建出的 amai-mcp。
    @Test("an out-of-range numeric limit is clamped instead of crashing amai-mcp", arguments: ["1e300", "-1e300", "9223372036854775808"])
    func outOfRangeLimit(_ limit: String) async throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/amai-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build amai-mcp first: swift build --product amai-mcp")
        let f = try Fixture(enabled: true, categories: ["work"])
        defer { f.cleanup() }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--config", f.config.path]
        let toServer = Pipe(), fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        try process.run()

        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_memory","arguments":{"query":"同步","limit":\#(limit)}}}"#,
        ]
        toServer.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        // 给服务端处理的时间，再关闭输入让它正常退出。
        try await Task.sleep(for: .seconds(1))
        try toServer.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
        let output = String(decoding: fromServer.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "status \(process.terminationStatus)")
        #expect(output.contains(#""id":2"#), "no response to the tool call")
        #expect(output.contains("离线同步队列已完成") && output.contains(#""isError":false"#), "\(output.suffix(400))")
    }

    @Test("limit parsing clamps every JSON number and falls back on other types")
    func limitParsing() {
        let max = MemoryAPI.maxSearchLimit
        #expect(AmaiMCPServer.limit(nil) == 10)
        #expect(AmaiMCPServer.limit(.int(5)) == 5)
        #expect(AmaiMCPServer.limit(.int(0)) == 1)
        #expect(AmaiMCPServer.limit(.int(Int.max)) == max)
        #expect(AmaiMCPServer.limit(.int(Int.min)) == 1)
        #expect(AmaiMCPServer.limit(.double(2.9)) == 2)
        #expect(AmaiMCPServer.limit(.double(1e300)) == max)
        #expect(AmaiMCPServer.limit(.double(-1e300)) == 1)
        #expect(AmaiMCPServer.limit(.double(.nan)) == 10)
        #expect(AmaiMCPServer.limit(.double(.infinity)) == 10)
        #expect(AmaiMCPServer.limit(.string("20")) == 10)
        #expect(AmaiMCPServer.limit(.null) == 10)
    }
}
