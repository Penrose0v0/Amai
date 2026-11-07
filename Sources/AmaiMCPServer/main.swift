import AmaiCore
import AmaiMCP
import Foundation
import MCP

// amai-mcp：只读 MCP Server，经 stdio 与外部 Agent 通信（ADR-0008）。
//
//   amai-mcp                    读取 ~/Library/Application Support/Amai/config.json
//   amai-mcp --config <路径>    使用指定的配置文件（测试或示例数据用）
//
// stdout 只用于 MCP 消息；诊断信息写 stderr。

let arguments = CommandLine.arguments
let configURL: URL
if let i = arguments.firstIndex(of: "--config"), i + 1 < arguments.count {
    configURL = URL(fileURLWithPath: (arguments[i + 1] as NSString).expandingTildeInPath)
} else {
    do {
        configURL = try AmaiPaths.standard().config
    } catch {
        FileHandle.standardError.write(Data("amai-mcp: cannot locate Amai's config: \(error)\n".utf8))
        exit(1)
    }
}

let amai = AmaiMCPServer(configURL: configURL)
let server = await amai.makeServer()
await amai.register(on: server)
do {
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("amai-mcp: \(error)\n".utf8))
    exit(1)
}
