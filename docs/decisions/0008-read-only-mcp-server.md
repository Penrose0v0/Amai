# 0008 · 统一的只读 Memory API 与 MCP Server

- 状态：**Accepted**（2026-11-06 用户确认：官方 Swift SDK；默认关闭；启用后默认只开放 general / work / goals）
- 日期：2026-11-06

## 背景

外部 Agent（Claude Desktop、Atd 等）需要读取 Amai 的记忆；今后 Eira Assistant 也会内置到 Amai 中，同样需要读取记忆。ADR-0006 已把 `MemoryLibrary` 定为统一的只读接口、以 `MemoryCategory` 为授权单位，但还没有面向外部的接口，也没有授权与开关。

## 决策

- **统一的 Memory API**（`AmaiMemory/MemoryAPI.swift`）：建立在 `MemoryLibrary`（Markdown 原文）与 `MemoryIndex`（派生全文索引）之上，不另建存储。
  - `search(query, limit)`：在已授权分区中全文检索；长期记忆的命中展开为具体条目（小节、内容、来源日期、kind），daily 返回 section 摘录与日期。
  - `timeline(on: date)`：解析当天 daily 的时间线区块（起止时间、标题、摘要、置信度、低置信标记）与日终摘要。
  - `memory(category, topic?)`：按小节返回分区条目与用户手写部分；`topic` 接受三种语言的推荐小节名，也接受部分匹配（项目名）。
  - 所有调用先经过 `MemoryAccess`（可读分区集合）。返回值都是 `Codable` 结构。
  - App 内部（今后的 Eira Assistant）直接调用 `MemoryAPI`，**不经过 MCP**。
- **MCP Server**（`amai-mcp`，target `AmaiMCP` + `AmaiMCPServer`）：标准 MCP，stdio 传输，三个 Tools `search_memory` / `get_timeline` / `get_memory`，均标注 `readOnlyHint: true`、`openWorldHint: false`。随 App 打包在 `Amai.app/Contents/MacOS/amai-mcp`，由外部 Agent 以子进程启动。
- **开关与授权**：`config.json` 的 `mcp` 段，`enabled` 默认 `false`；`categories` 默认 `general / work / goals`，daily（时间线）、health、finance 需用户自己加入。`amai-mcp` 每次调用都重新读取配置：关闭、配置缺失或无效时一律拒绝（fail closed），修改后下一次调用即生效。App 只负责原样保留这一段，这一版不提供界面开关。
- **只读**：`amai-mcp` 不写记忆文件，不触发同步或整理，不联网。检索使用进程内存中的 `MemoryIndex`（每次检索前按文件修改时间增量刷新），不读写 App 的索引数据库，两个进程之间没有锁竞争。日志不记录查询与记忆内容。

## 备选方案

- **手写 JSON-RPC**：零依赖，约 300 行；但协议版本升级（初始化协商、通知、批处理等）要自己跟进。未采用。
- **读取 App 的 `memory.sqlite`**：省去重建索引，但两个进程共用一个 WAL 数据库，打开时还会运行迁移（写操作）。索引只是派生数据，记忆目录规模小，进程内重建更简单。未采用。
- **HTTP / SSE 传输**：要监听端口并处理本机其他进程的访问控制。stdio 只对启动它的客户端可见，先只支持 stdio。
- **时间线读取抽取层的 `ExtractionStore`**：信息更全（关键帧、观察），但属于抽取层数据，且包含尚未进入记忆的内容。MCP 只暴露记忆层，daily 的时间线区块每分钟同步一次，已经足够及时。

## 取舍与风险

- 依赖官方 `modelcontextprotocol/swift-sdk` 0.12.1（`exact` 锁定），它带入 swift-system、swift-log、eventsource（swift-nio 只用于 SDK 自带的示例服务器，不进入 `MCP` 产物）。只有 `AmaiMCP` 依赖它，App 本体不链接。SDK 仍是 0.x，升级时需检查 API 变化。
- 启用后，外部 Agent 读到的记忆会作为上下文发送给该 Agent 使用的模型服务，这超出 Amai 自己的外发控制。因此默认关闭、按分区授权，并在 `docs/mcp.md` 中说明。
- 授权以分区为单位，不能细到条目；General 中可能概括了 Health / Finance 的高层信息（ADR-0006 的 General 规则），开放 General 时这一点需要用户知情。
- 外部 Agent 能否只调用只读工具，取决于客户端；`amai-mcp` 本身不提供任何写操作。

## 影响

- 新增 `AmaiMemory/MemoryAPI.swift`、`AmaiMCP`、`AmaiMCPServer`、`Tests/AmaiMCPTests`；`scripts/bundle.sh` 打包并签名 `amai-mcp`；`AppConfiguration` 增加 `mcp` 段。
- 不修改感知、抽取、记忆写入与整理逻辑，不修改界面。
- 接入说明见 `docs/mcp.md`。
