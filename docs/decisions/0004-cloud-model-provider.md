# 0004 · 记忆整理可切换到云端 API 大模型

- 状态：**Accepted**（2026-10-20 用户确认：同时支持 Anthropic 与 OpenAI，其余按推荐；已在 M4.1 实现）
- 日期：2026-10-20

## 背景

用户确定的方向（2026-10-20）：

- 抽取层继续用本地小模型。截图量大、调用频繁，而且画面最敏感。
- 记忆整理优先用云端 API 大模型。长期记忆的筛选、整合与更新需要更强的推理能力，而每天只调用几次。
- 整理模型可以切换，用户自行配置 API Key 与模型；默认保留本地模式，保护隐私。
- 不把整理绑定到 e4b，也暂不专门适配本地 26b。

M4 已经留好接口：记忆层通过 `MemoryLanguageModel` 调用模型（M3 提案中称为 TextGenerating），App 用 `ProviderLanguageModel` 把本地模型接进来。本任务在这个接口后面加一个云端实现，再加上配置与隐私控制，整理逻辑本身不变。

## 提案

### 1. 结构

```text
Consolidator ──► MemoryLanguageModel（不变）
                   ├── LocalLanguageModel      现有 ProviderLanguageModel 改名，走本地 MLX
                   └── CloudLanguageModel      新增，经 AmaiCloud 调用 Anthropic 或 OpenAI
抽取层 ──► MLXModelProvider（不变，始终本地）
```

- **只有记忆整理可以走云端**。抽取层的帧描述与活动切分不提供云端选项，截图与 OCR 原文因此永远不离开本机。
- `MemoryLanguageModel` 只加一个可选能力：调用方提供 JSON Schema 时，云端实现用 API 的结构化输出功能保证返回合法 JSON，本地实现照旧解析。这样可以去掉云端路径上"模型输出解析失败"这类问题。

### 2. 云端实现（原始 HTTP，`AmaiCloud` target）

两家共用同一份输出 Schema（全部字段必填、不允许额外字段，满足双方的结构化输出要求）。

**OpenAI（Chat Completions）**：`POST {baseURL}/chat/completions`，`Authorization: Bearer`；`response_format` 为 strict `json_schema`；`reasoning_effort` 仅在用户设置时发送；`message.refusal` 视为拒绝，`finish_reason: length` 视为截断。API 地址可改，便于使用兼容该接口的服务。OpenAI 没有默认模型，需用户填写。

**Anthropic（Messages API）**：

Swift 没有官方 Anthropic SDK，用 `URLSession` 直接调用：

- `POST https://api.anthropic.com/v1/messages`，请求头 `x-api-key`、`anthropic-version: 2023-06-01`、`content-type: application/json`。
- 默认模型 `claude-opus-5-5`，可配置为任意模型 ID。这款模型的思考始终开启，用 `output_config.effort` 控制深度，整理任务默认 `high`。
- 结构化输出：用 `output_config.format` 传入每个任务的 JSON Schema（日终摘要、专题、summary 各一份）。具体字段形状在实施时对照官方文档核对。
- 返回处理：先检查 `stop_reason`。遇到 `refusal`（安全分类器拒绝）或 `max_tokens`（输出被截断）时按失败处理，不写入。
- 超时 120 秒。429、5xx 与网络错误按指数退避重试 2 次；4xx 不重试，在状态里显示原因（例如 Key 无效）。
- 提示词缓存：调用频率很低，缓存在两次调用之间早已过期，不使用。

### 3. 配置

`config.json` 新增顶层字段：

```json
"consolidationModel": {
  "mode": "local",
  "provider": "anthropic",
  "anthropicModel": "claude-opus-5-5",
  "anthropicEffort": "high",
  "openaiModel": "",
  "openaiReasoningEffort": "",
  "openaiBaseURL": "https://api.openai.com/v1"
}
```

- `mode` 默认 `local`。
- **API Key 只存 macOS 钥匙串**（服务名 `com.amai.app.anthropic` / `com.amai.app.openai`），不写进 config.json，不进日志，界面上只显示末 4 位。
- 菜单新增"记忆整理模型…"设置窗口：模式切换、模型 ID、effort、API Key 输入框，以及"测试连接"按钮。测试用一次很小的请求，不发送任何记忆内容。

### 4. 隐私控制

- **开启云端前明确确认**。弹窗写清会发送什么、不会发送什么：
  - 会发送：daily 文件全文（时间线、日终摘要、你手写的笔记）、work 专题条目、summary.md 全文（含你手写的部分）。
  - 不会发送：截图、OCR 原文、观察记录、原始数据。
- 发送前对全部文本做一次凭据脱敏（复用 `SecretRedactor`）。
- 菜单常驻显示当前整理模型，例如"整理：云端 · claude-opus-5-5"。
- 日志只记录次数、耗时与 token 用量，不记录内容。
- 弹窗中说明：数据按 Anthropic API 的数据保留政策处理，请用户在 Anthropic 控制台确认自己组织的保留设置。不在 Amai 文档里转述具体天数，避免过时。
- 用户随时可以切回本地，切换立即生效。

### 5. 失败行为

云端失败时**不自动退回本地模型**。这一天保持"未整理"，下一轮（10 分钟后）重试，菜单显示错误。

理由：如果悄悄换成本地模型，长期记忆的质量会忽高忽低，用户也无从知道哪些内容出自哪个模型。快照与改动日志会记录每次整理使用的模型标识。

### 6. 成本估计（粗略，实施后用真实 token 用量校准）

| 任务 | 频率 | 每次约 | 按 claude-opus-5-5（$4 / $20 每百万 token） |
|---|---|---|---|
| 日终摘要 + 专题 | 每天 2 次调用 | 输入 1.5 万、输出 3 千 token | 约 $0.12 / 天 |
| summary | 每周 1 次 | 输入 2 万、输出 3 千 token | 约 $0.14 / 周 |

合计约每月 4 美元。思考 token 计入输出，effort 越高越贵，实施后以 API 返回的 `usage` 为准。

### 7. 测试

- 用 `URLProtocol` 拦截请求做单元测试：检查请求头与请求体、Key 不出现在日志中、各种状态码与 `stop_reason` 的处理、重试与退避。
- 测试钥匙串的读写与删除。
- 测试模式切换后 Consolidator 使用的实现是否正确，以及云端失败不会退回本地。
- 真机：用你的 Key 跑一次"整理今天"，对比本地 e4b 的结果，并记录 token 用量与耗时。

## 需要你决定的点

1. ~~只支持 Anthropic~~ → **Anthropic 与 OpenAI 都支持**（用户决定）。
2. Anthropic 默认 `claude-opus-5-5`，effort `high`；OpenAI 由用户填写模型。
3. 云端失败不退回本地，等待重试。
4. API Key 存钥匙串，不放 config.json。

## 影响

- `AmaiMemory`：`MemoryLanguageModel` 增加可选的 JSON Schema 参数；三个整理任务各提供一份 Schema。
- 新 target `AmaiCloud`（两家客户端、HTTP 重试、钥匙串），不依赖任何层；App 用 `CloudLanguageModel` 把它接到记忆层。
- App：设置窗口、钥匙串、开启确认弹窗、菜单状态。
- 文档：architecture.md 的外部数据传输边界、product.md 的隐私需求同步更新。
