# 0005 · 用 ChatGPT / Claude 订阅额度做记忆整理

- 状态：**Accepted**（2026-10-22 用户确认：Amai 采用 Open Core 模式，核心开源、本地运行；两种订阅接入都实施）
- 日期：2026-10-22
- 相关：ADR-0004（API Key 与云端模型），本 ADR 在其基础上增加两种整理模型来源

## 背景

记忆整理每天只调用几次模型，用户希望直接使用已有的 ChatGPT / Claude 订阅额度，不必另开 API 账户。约束：只用官方支持的接入方式，不使用非公开接口，不提取或保存他人程序的凭据，不绕过订阅额度。

2026-10-21 至 22 日对两家官方文档的调研结论如下。

| | OpenAI | Anthropic |
|---|---|---|
| 官方机制 | Sign in with ChatGPT（SIWC）的 ChatGPT plan usage：OAuth 授权后，用用户的套餐额度调用 Responses API | 无面向第三方应用的订阅授权。Agent SDK 文档："除非事先获批，Anthropic 不允许第三方开发者在其产品中提供 claude.ai 登录或额度" |
| 适用条件 | 开源项目、本地运行的个人项目、经挑选的私有应用；付费或托管应用需排候补 | 用户在自己的电脑上用自己的订阅登录、运行未修改的 Claude Code，不受限制（Claude Code 合规页） |
| Amai 的位置 | Open Core、核心开源、本地运行：符合 | 驱动用户本机已登录的 `claude -p`，Amai 不接触任何凭据：文档未明确表态，个人自用可接受 |

OpenClaw 的默认做法两家都不采用：OpenAI 方面它借用 Codex CLI 的 client ID（OpenAI 没有文档允许）；Anthropic 方面它让用户粘贴 `claude setup-token` 生成的令牌并保存（合规页禁止开发者"收集、保存或转发"凭据）。OpenClaw 的 `--method siwc` 测试版与本 ADR 的 OpenAI 方案一致。

## 决策

整理模型的来源从两种扩展为四种：**本地模型**（默认）、**API Key**（ADR-0004）、**ChatGPT 订阅**、**Claude Code 订阅**。四者都实现记忆层的 `MemoryLanguageModel`，可在运行时切换；抽取层始终本地。

### ChatGPT 订阅：官方 SIWC

- **授权**：浏览器 OAuth + PKCE（S256），回调 `http://127.0.0.1:1455/auth/callback`（端口被占用时换端口，只有端口可变）。首次用 `client_id=dynamic_agent_client` 与 `agent_name_hint=Amai` 注册，回调返回的 `oaiapp_…` client ID 按账户保存并在之后复用。`ext_agent_host_id` 为本机首次生成的 `urn:uuid:…`，永久保存，退出登录也不变。
- **范围**：`openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`，`resource=https://api.openai.com/v1`。授权结果中没有 `chatgpt.tokens.use.direct` 时，视为未开启套餐用量，不调用。
- **校验**：用 OpenAI 公布的 JWKS 验证 ID token 的 RS256 签名，并检查 issuer、audience（签发的 client ID）、有效期与 nonce。
- **存储**：令牌记录（client ID、host ID、ID/访问/刷新令牌、到期时间、范围、邮箱）以 JSON 存入 macOS 钥匙串，不落盘、不进日志。
- **刷新**：访问令牌 1 小时有效，到期前 5 分钟刷新，刷新令牌轮换保存；刷新串行进行。刷新返回 `invalid_grant` 等终止性错误时清掉令牌，提示重新登录。
- **调用**：`POST https://api.openai.com/v1/responses`，`store:false`、`stream:true`，系统提示放 `instructions`，不发送 `temperature`、`max_output_tokens` 等不支持字段。只有收到 `response.completed` 才算成功。
- **结构化输出**：官方文档未说明 SIWC 路由是否支持 `text.format` 的 JSON Schema。实现时先带上；若返回 `subscription_sharing_unsupported_capability` 且指向该参数，本次会话改为不带 Schema，靠提示词约束 JSON，由记忆层照常解析。
- **模型选择**：`GET /v1/models`，保留 `visibility == "list"` 的条目，界面显示 `display_name`，请求使用 `slug`。
- **错误**：按官方错误码处理。额度用尽（`subscription_sharing_usage_limit_exceeded`）暂停并给出 "Manage usage"；套餐不符合条件不重试；503 类错误有界退避。
- **界面**：遵循官方 UI 规范，登录按钮为 "Continue with ChatGPT"；首次登录后显示一次 "You're using your ChatGPT plan" 说明，按钮 "Got it"；菜单显示 "Using ChatGPT plan"，并提供 "Manage usage"。
- **退出登录**：调用 OpenID 配置中的 `revocation_endpoint` 撤销刷新令牌，再清除本地记录；撤销失败时提示用户在 ChatGPT 设置中断开 Amai。

### Claude Code 订阅：本机 `claude -p`

- **原则**：Amai 只启动用户自己安装、已登录、未修改的 Claude Code 程序，不读取、不保存、不转发任何账户凭据，不调用 claude.ai 的任何接口。登录由用户在终端里自己完成（`claude` → `/login`）。
- **调用**：

  ```text
  claude -p --output-format json --json-schema <schema> --model <model>
         --system-prompt <整理提示词> --tools "" --no-session-persistence
         --setting-sources project --strict-mcp-config --disable-slash-commands
  ```

  提示正文经标准输入传入。在一个专用的空工作目录中运行，不加载用户全局设置、钩子、MCP 服务器与技能，关闭全部工具，只生成文字。
- **环境变量**：子进程只拿到 `HOME`、`PATH`、`USER`、`LOGNAME`、`TMPDIR`、`LANG`。不传递 `ANTHROPIC_API_KEY` 等变量：官方文档说明 `-p` 模式下只要存在 API Key 就会改用 API 计费。
- **定位程序**：先用设置中指定的路径；否则依次查找常见安装位置（`~/.claude/local`、`~/.local/bin`、Homebrew、`/usr/local/bin`、nvm 各版本目录）。
- **结构化输出**：读取返回 JSON 中的 `structured_output`；缺失时退回 `result` 文本。
- **模型选择**：`opus`、`sonnet`、`haiku` 别名，或完整模型 ID。默认 `opus`。
- **连接检查**：运行 `claude --version` 与 `claude auth status`，只读取其输出中的登录状态、登录方式和订阅类型。
- **错误**：`is_error` 为真时，按结果文本区分"未登录""额度用尽""模型不可用"等情况；超时 300 秒后终止子进程。
- **限制说明**：个人自用。Amai 若向他人分发包含此功能的版本，需先取得 Anthropic 的书面确认；在此之前，设置界面明确标注"个人使用"。

### 隐私

- 两种订阅方式发送的内容与 API Key 方式相同：只有记忆文本（daily、work 专题、summary），不含截图、OCR 原文与观察记录；发送前统一做凭据脱敏。
- 首次切换到任一云端来源时都要确认，确认框写明数据发往哪家服务。
- 失败时不退回其他来源，当天保持未整理并在下一轮重试（沿用 ADR-0004）。

## 已放弃的方案

| 方案 | 原因 |
|---|---|
| 借用 Codex CLI 的 client ID 登录 ChatGPT（OpenClaw 默认做法） | OpenAI 没有文档允许第三方使用 Codex 的 client |
| 读取 `~/.codex/auth.json` 或 Claude Code 的钥匙串 / `~/.claude/.credentials.json` | 属于提取其他程序的凭据 |
| 让用户粘贴 `claude setup-token` 并由 Amai 保存 | Claude Code 合规页禁止开发者收集、保存或转发凭据 |
| 用 Claude Agent SDK 走订阅登录 | SDK 文档明确不允许第三方提供 claude.ai 登录 |
| 运行用户的 `codex exec` | OpenAI 建议自动化场景使用 API Key，未许可第三方包装 |

## 未核实与风险

- ~~SIWC 路由是否支持 JSON Schema 结构化输出~~：2026-10-22 真机确认支持（`gpt-6.1-sol`，`text.format` 的 strict JSON Schema 正常返回）；退路保留以防变化。
- SIWC 每个应用的额度上限只见于媒体报道。
- Claude Code 子进程方式在分发场景下的许可（需 Anthropic 书面确认）。
- 两种方式都依赖对方程序或接口的行为，升级后可能变化；连接检查与清楚的错误提示是主要缓解手段。

## 影响

- `AmaiCloud` 新增：SIWC 授权会话（本机回调服务、PKCE、JWKS 校验、钥匙串、刷新与撤销）、ChatGPT 套餐客户端（Responses API 流式解析）、Claude Code 子进程客户端与程序定位。
- `consolidationModel.mode` 扩展为 `local`、`apiKey`、`chatgptPlan`、`claudeCode`；旧值 `cloud` 读作 `apiKey`。
- 设置窗口新增两种订阅的登录 / 状态 / 模型选择 / 连接测试。
