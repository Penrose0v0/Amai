# 用 MCP 读取 Amai 的记忆

Amai 带有一个只读的 MCP Server `amai-mcp`（ADR-0008）。Claude Desktop、Atd、Claude Code 等支持 MCP 的 Agent 可以通过它搜索和读取你的记忆。它**默认关闭**。

## 能读到什么

| Tool | 参数 | 返回 | 需要的分区 |
|---|---|---|---|
| `search_memory` | `query`，`limit`（1–50，默认 10） | 匹配的条目：分区、小节、内容、日期、来源日期、依据类型（observed / stated / inferred / confirmed） | 只搜索已开放的分区 |
| `get_timeline` | `date`（`YYYY-MM-DD`、`today`、`yesterday`） | 当天的活动片段（起止时间、标题、摘要、置信度、低置信标记）、日终摘要、手写笔记 | `daily` |
| `get_memory` | `category`（general / work / health / finance / goals），`topic`（可选，小节名或项目名） | 按小节分组的条目（来源日期、依据类型、结构化字段）、你手写的内容、可选的专题列表 | 对应分区 |

- 只读：不会修改、删除或新增任何记忆，也不触发整理。
- 不联网：`amai-mcp` 只读取本机的 Markdown 文件。
- 时间线和大多数条目是模型根据屏幕活动推断的，`kind` 标明依据。

## 启用

编辑 `~/Library/Application Support/Amai/config.json` 中的 `mcp` 段（Amai 启动后会自动写入默认值）：

```json
"mcp" : {
  "enabled" : true,
  "categories" : ["general", "work", "goals"]
}
```

- `enabled`：默认 `false`。为 `false`、或配置文件缺失、无法解析时，所有调用都被拒绝。
- `categories`：可读的分区。默认只有 `general`、`work`、`goals`；要让 Agent 读取时间线，加入 `daily`；`health`、`finance` 同理。
- 修改后**立即生效**（每次调用都重新读取配置），不需要重启 Amai 或 Agent。随时把 `enabled` 改回 `false` 即可停止访问。

> **注意**：Agent 读到的记忆会作为上下文发送给它所使用的模型服务（例如 Anthropic、OpenAI）。这部分外发不受 Amai 控制。只开放你愿意让该 Agent 使用的分区。`general` 中可能包含其他分区的高层概括。

## 接入

下面的路径假设 Amai 位于 `/Applications/Amai.app`。开发构建位于 `<仓库>/.build/Amai.app`，请相应替换。

### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`，然后完全退出并重新打开 Claude Desktop：

```json
{
  "mcpServers": {
    "amai": {
      "command": "/Applications/Amai.app/Contents/MacOS/amai-mcp"
    }
  }
}
```

连接日志位于 `~/Library/Logs/Claude/mcp-server-amai.log`。

### Atd

在 Atd 的设置中添加 MCP 服务器：

- 传输：stdio
- 命令：`/Applications/Amai.app/Contents/MacOS/amai-mcp`
- 参数、环境变量、工作目录：留空

Atd 首次启动 stdio 服务器时会请求你批准，批准后即可在任务中使用。三个 Tool 都标注为只读，可以设置为自动批准。

### Claude Code

```bash
claude mcp add amai -- /Applications/Amai.app/Contents/MacOS/amai-mcp
```

### 其他客户端

任何支持 stdio 的 MCP 客户端都可以：命令是 `amai-mcp`，不需要参数。

## 用示例数据试用

`--config <路径>` 让 `amai-mcp` 使用另一份配置，可以指向合成示例，不碰真实记忆：

```bash
DIR=$(mktemp -d)
cp -R samples/memory-preview "$DIR/memory"
cat > "$DIR/config.json" <<EOF
{"memory": {"root": "$DIR/memory"}, "mcp": {"enabled": true, "categories": ["general", "work", "goals", "daily"]}}
EOF
# 客户端配置中加上参数：
#   "args": ["--config", "<DIR>/config.json"]
```

## 开发

- 接口实现：`Sources/AmaiMemory/MemoryAPI.swift`（App 内部与 MCP 共用）；MCP 适配：`Sources/AmaiMCP/`；入口：`Sources/AmaiMCPServer/main.swift`。
- 测试：`swift build --product amai-mcp && swift test --filter "MemoryAPITests|AmaiMCPServerTests"`。其中一个测试以子进程方式启动构建出的 `amai-mcp`，经 stdio 完整走一遍握手与调用。
