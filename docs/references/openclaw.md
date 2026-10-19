# OpenClaw

> 基本信息：
> - 地址：https://github.com/openclaw/openclaw
> - 许可证：MIT（GitHub API `license.spdx_id = MIT`）
> - 主要语言/技术栈：TypeScript（约 424 MB 源码，占绝对多数），辅以 Swift / Kotlin（移动端与 macOS 应用）、少量 Rust；Node.js + pnpm workspace；索引与状态使用 SQLite（可选 PostgreSQL）
> - 活跃度（截至 2026-10-19）：约 392k stars、82k forks；仓库创建于 2025-11-24；`main` 分支最新提交日期为 2026-10-19，当天即有十余次合并，属于极高活跃度项目
> - 本文调研日期：2026-10-19。OpenClaw 迭代极快，文档镜像之间存在版本差异，下文以 docs.openclaw.ai 当前页面为准，差异处已注明。

## 项目定位

OpenClaw 是一个运行在用户自有硬件上的通用 AI 助手（"The AI that really does things"），通过 Discord / Slack / Telegram / WhatsApp 等聊天平台与用户交互，由本地 Gateway 进程托管多个 Agent，强调"状态、记忆与凭据都留在你的机器上"。

它不是环境感知系统：所有输入都来自用户主动发送的消息、工具调用结果和定时任务。但它的记忆层是目前开源 Agent 中少数把"Markdown 文件为唯一事实来源 + SQLite 派生索引 + 后台整合"做完整的实现，与 Amai 的 Markdown-based Memory 方向高度相关。

## 记忆系统概览

OpenClaw 的记忆由核心插件 `memory-core`（源码位于 `extensions/memory-core/`）实现，官方文档将其划分为五个层级（tier）：

| 层级 | 载体 | 写入者 | 注入方式 |
|---|---|---|---|
| 指令层 Instructions | `AGENTS.md`、`SOUL.md` 等工作区指令文件 | 仅人类 | 每次会话开始时注入 |
| 精选核心 Curated core | `MEMORY.md`、`USER.md` | Dreaming 整合流程，或用户明确要求 | 会话开始时注入（受预算限制，且仅限私有主会话） |
| 情景层 Episodic | `memory/YYYY-MM-DD.md` 日记、会话转录 | Agent 在工作中、压缩前 flush、转录捕获 | 仅在检索时按需读取，不自动注入 |
| 前瞻层 Prospective | 待触发意图（SQLite）、cron 任务 | `intent` 工具、定时任务 | 仅在触发条件满足时 |
| 审阅层 Review | `DREAMS.md`、dreaming 报告 | Dreaming 各阶段 | 从不注入，供人阅读 |

核心原则（官方文档"Design Rationale"原文概括）：

1. **No hidden state**：模型只记得写进工作区文件的内容。
2. **写入才是难点**：引用 LongMemEval 指出"写什么"比"怎么索引"更重要，因此整理在后台进行，不在回复路径上。
3. **写路径是安全边界**：来源（provenance）在写入时记录，晋升由结构性门槛控制，而非事后检测"坏记忆"。
4. **固定规则包裹模型判断**：评分、阈值、资格由确定性代码决定，模型只负责语言层面的判断。
5. **记忆失败不阻塞回复**：回复路径上的每个记忆步骤都有超时或回退。

## 存储格式与目录结构

工作区默认在 `~/.openclaw/workspace`（可通过 `OPENCLAW_WORKSPACE_DIR`、`agents.defaults.workspace`、`agents.entries.*.workspace` 覆盖）。与记忆相关的文件：

| 路径 | 内容 | 说明 |
|---|---|---|
| `MEMORY.md`（可选） | 精选长期记忆：持久事实、决策、摘要 | 仅在主私有会话注入；群聊/共享上下文不加载 |
| `USER.md`（可选） | 稳定的用户偏好、沟通风格、关系、进行中项目 | 单独 4,000 字符预算；OpenClaw 不会自动创建 |
| `memory/YYYY-MM-DD.md` | 每日日志（观察、工作上下文、会话摘要） | 仅在 `/new`、`/reset` 时读取今天和昨天的文件 |
| `memory/YYYY-MM-DD-<slug>.md` 或 `YYYY-MM-DD-HHMM.md` | 由 `session-memory` 钩子写入的会话节选 | 与日期文件一同被索引 |
| `memory/imports/{codex,claude-code,hermes}/` | 从其他 Agent 导入的记忆副本 | 仅索引，不合并进 `MEMORY.md` |
| `DREAMS.md` | Dreaming 的"梦境日记"与阶段摘要 | 人类审阅用 |
| `memory/dreaming/<phase>/YYYY-MM-DD.md` | 可选的阶段报告 | |
| `AGENTS.md`、`SOUL.md`、`IDENTITY.md`、`BOOTSTRAP.md`、`BOOT.md` | 指令/人格/引导文件 | 非记忆，但共享同一注入预算 |

派生数据（不是事实来源）：

- 索引、会话转录、dreaming 状态、来源信息都存放在每个 Agent 一个的 SQLite 文件 `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`；归档转录在 `~/.openclaw/agents/<agentId>/sessions/`。
- `openclaw memory reset` 只清派生数据，Markdown 文件、会话与 schema 保留；`openclaw memory index --force` 可完全重建。

**格式约定**：

- `USER.md` 条目被要求写成祈使句式的"指令"（Always / Never / Prefer），每条带状态元数据（观察日期、active / superseded）。偏好变化时原地改写而非追加矛盾条目——文档明确说明原因是"追加式偏好历史会让模型用过期值回答"。文档只描述了契约，未给出字面模板（未验证具体语法）。
- `MEMORY.md` 中由 Dreaming 晋升的条目必须包含 `Source: path#Lx-Ly` 形式的来源引用。
- 没有 YAML frontmatter 的要求（未验证是否有可选 frontmatter）。

**大小限制**：

- `agents.defaults.bootstrapMaxChars`（默认 20,000）限制每个注入文件；`agents.defaults.bootstrapTotalMaxChars`（默认 60,000）限制总量；`USER.md` 单独 4,000 字符。超限时磁盘文件不变，仅注入副本被截断，可用 `/context list`、`/context detail`、`openclaw doctor` 查看。
- 编辑器与 `agents.files.set` 拒绝超过 2 MiB 的单文件保存。

## 写入机制

**谁在写**：

1. **Agent 主动写**：用户说"记住我偏好 TypeScript"时，Agent 通过文件工具写入；生成的工作区指令鼓励在工作中记录持久事实。路由规则：稳定偏好 → `USER.md`（原地取代）；持久非画像事实 → `MEMORY.md`；详细工作上下文 → 日记。
2. **压缩前 flush（memory flush）**：上下文接近窗口上限触发压缩前，先运行一个静默回合提醒 Agent 保存重要内容。默认开启，`agents.defaults.compaction.memoryFlush.enabled: false` 关闭，`.model` 可为此回合单独指定模型（如本地小模型）。flush 期间 `write` 只允许**追加到当日日记**，且必须是新内容——整段回放或复制段落会被拒绝。flush 失败不影响压缩继续。文档明确说明 flush 写入**不对改写（paraphrase）去重**。
3. **`session-memory` 捆绑钩子**：在 `command:new`、`command:reset`、`session:auto-reset` 事件上，后台把上一会话最近 N 条（默认 `messages: 15`）用户/助手消息写入 `<workspace>/memory/YYYY-MM-DD-HHMM.md`，可选 `llmSlug` 让模型起文件名。是否默认启用未在文档中说明（未验证）。
4. **Dreaming 后台整合**：唯一能"晋升"内容进 `MEMORY.md` 的自动路径，见下一节。
5. **人类直接编辑**：工作区是普通文件，文档推荐放进私有 git 仓库备份。

**来源与信任（provenance）**：每个索引条目在 SQLite 中记录封闭集合的来源类别，模型无法通过文本改写它：

| 类别 | 含义 |
|---|---|
| `owner` | 所有者在可信渠道亲自输入 |
| `agent` | Agent 从所有者内容推导 |
| `untrusted` | 来自外部内容：网页、工具输出、群聊中的非所有者 |
| `system` | 运行时指令：心跳提示、cron 前言 |

附加规则：分类保守，来源不明且外部推导的一律 `untrusted`；cron / heartbeat / 子 Agent 会话不产生可晋升的候选；一个回合内只要有工具声明了网络来源输出，该回合余下内容都被标记 `untrusted`（下一条用户消息清除）；memory flush 为整个文件记录"最不可信"类别，导致同文件中的可信行也失去晋升资格。被召回注入的内容会被结构性标记，不会被再次提取为新记忆。

**事实 vs 推断**：没有显式的"事实 / 推断"字段。替代方案是上面的来源类别 + 观察时间戳 + 可选的 supersession key。这是一种"按来源可信度"而非"按认识论性质"的区分。

## 检索与索引

默认引擎是内置 SQLite（`memory-core`），可替换为 Honcho、LanceDB（`memory-lancedb`）插件或实验性 PostgreSQL。

**索引**：

- 来源：`MEMORY.md`、根目录 `USER.md`、`memory/*.md`；`memory.search.extraPaths` 可加目录；`memory.search.sources` 加入 `"sessions"` 并设 `experimental.sessionMemory: true` 才索引会话转录。
- 分块：默认 400 token，80 token 重叠。
- 关键词：FTS5 + BM25；分词器 `store.fts.tokenizer` 默认 `unicode61`，CJK 可用 `trigram`。
- 向量：嵌入存为小端 float64 BLOB，`sqlite-vec` 为可选加速，缺失时回退到进程内余弦。
- 嵌入提供方 `memory.search.provider`：默认 `"openai"`（`text-embedding-3-small`），可选 `local`（llama.cpp GGUF，`memory.search.local.modelPath`）、`ollama`、`lmstudio`、`gemini`、`voyage`、`mistral`、`bedrock`、`deepinfra`、`github-copilot`、`openai-compatible`；设为 `"none"` 则仅关键词检索。显式远端 provider 不可用时不会静默回退到 FTS，而是返回"不可用"。
- 文件监听：1.5 s 去抖增量重建；全量重建先写临时库再原子发布，失败不影响旧索引。会话索引等待 30 s 无变化才运行，失败按 1 / 5 / 15 分钟重试。

**排序（固定规则，不可配置）**：混合相关度（向量 + 关键词并行后加权合并）× 30 天半衰期的时间衰减（只对 `YYYY-MM-DD.md` 日记生效，`MEMORY.md`、`USER.md` 和无日期文件视为"常青"不衰减）× 写入时一次性打分的重要度（缺省中性）；最后用 λ=0.7 的 MMR 去重。`query.maxResults` 默认 6，`query.minScore` 默认 0.35（应用于衰减前的相关度）。

**工具**：

| 工具 | 作用 |
|---|---|
| `memory_search` | 语义 + 关键词检索，参数 `maxResults`（别名 `max_results`、`limit`），返回片段、Markdown 标题行号引用、分数；30 s 超时，语义部分超时时返回关键词部分结果并警告 |
| `memory_get` | 读取指定记忆文件或行区间 |
| `sessions_search` / `sessions_history` | 对原始转录的精确全文检索（最多 25 条、每条 300 字符、总 32 KiB），受 `tools.sessions.visibility` 约束；文档明确"节选保留原文，包括凭据" |
| `intent` | 创建 / 列出 / 取消事件触发的待办意图 |

**三条召回通道**：

1. **启动注入**：`AGENTS.md` 总是注入；`MEMORY.md`、`USER.md` 在来源合格时注入。
2. **触发召回（trigger recall）**：每条交互消息与索引条目的短触发短语比对，匹配分 ≥ 0.65 时最多注入 3 条精选条目到隐藏上下文，不调用模型；**只有** `MEMORY.md` / `USER.md` 中已晋升的可信条目有资格，日记和转录永远不自动注入。
3. **Active Memory 升级通道**（独立插件 `active-memory`）：`config.mode` 默认 `"escalate"`——仅当消息表现出回忆意图（提及过去、时间性措辞、询问先前决策）且通道 1/2 无强命中时，运行一个阻塞的子 Agent 跨历史检索，`timeoutMs` 默认 15,000，`maxSummaryChars` 默认 220，`allowedChatTypes` 默认 `["direct"]`，带熔断器（3 次超时后冷却 60 s）。`"always"` / `"off"` 可强制或关闭。是否默认启用插件未在文档中说明（未验证）。

**Token 预算**：注入侧由 `bootstrapMaxChars` / `bootstrapTotalMaxChars` 控制；检索侧由 `maxResults` 与 Active Memory 的 `maxSummaryChars` 控制；文档未给出 `memory_search` 结果的 token 上限（PostgreSQL 引擎有 200 条、700 字符片段上限）。

## 整合、摘要与遗忘

**Dreaming（后台整合）**：`memory-core` 的默认整合路径。当前官方页面明确写"Dreaming is enabled by default"，配置项 `plugins.entries.memory-core.config.dreaming.enabled` 默认 `true`（注意：部分旧版文档镜像称其为 opt-in，属版本差异）。通过一个自动管理的 cron 任务运行，`dreaming.frequency` 默认 `0 3 * * *`，`dreaming.timezone` 可设；多 Agent 部署需指定 `agents.defaults.systemAgent.agentId`。

每次 sweep 顺序执行三个内部阶段（不是用户可选模式）：

| 阶段 | 行为 | 是否写 `MEMORY.md` |
|---|---|---|
| Light | 整理近期短期材料、去重信号、暂存候选；写 `DREAMS.md` 的 `## Light Sleep` 托管块 | 否 |
| REM | 从近期痕迹生成主题与反思摘要；写 `## REM Sleep` 块 | 否 |
| Deep | 排序候选、从当前日记重新取回片段、更新 `MEMORY.md`，写 `## Deep Sleep` 摘要 | **唯一**会持久写入的阶段 |

晋升门槛（确定性代码）：候选必须同时通过 `minScore`（CLI 默认 0.75）、`minRecallCount`（默认 3）、`minUniqueQueries`（默认 3）三个阈值。综合评分权重：相关度 0.30、频率 0.24、查询多样性 0.15、时近性 0.15、已整合度 0.10、概念丰富度 0.06。即：**一条日记内容要被多次、以不同问题召回，才有资格进入长期记忆**——这是"按使用频率晋升"而非"按写入时判断重要性"。

合并与取代：一次不带工具的模型调用返回操作决策（新增 / 合并 / 取代），不返回替换后的正文；被接受的改写必须保留 ≥ 1 − `phases.deep.maxPriorEntryLossFraction`（默认 0.25）的既有条目、带 `Source:` 引用、在引导预算内、能被解析。模型不可用或校验失败时回退到仅追加。写入前做内容哈希校验 + 原子重命名，若文件被他人改动则放弃改写。每次改写的前像保存在 SQLite，并在 `DREAMS.md` 追加摘要。

硬性排除：来源为 `untrusted` / `system` 的候选在进入整合提示前被过滤（结构性前提，不是扣分）；cron / heartbeat / 子 Agent 会话不参与。

**遗忘**：

- `openclaw memory forget --agent <id> [--session|--hook-source|--participant|--since]`：按会话等选择器删除派生记忆——从扫描的记忆文件中删除晋升标记条目和会话引用段、从 `DREAMS.md` / `memory/dreaming/**` 删除精确引用行、清理改写备份、删除索引中的转录块、FTS 与向量行、短期状态、来源行，并清空该 Agent 的全部嵌入缓存。**不删除**原始会话转录与归档；文档承认"日记中未跟踪的改写可能残留"。无确认提示。
- 时间衰减只影响排序，不删除内容。
- 会话维护：`session.maintenance.pruneAfter` 默认 `"30d"`，`maxEntries` 默认 5000，超出归档最旧会话。

**回填与预览**：`openclaw memory promote`（默认仅预览，`--apply` 追加）、`promote-explain "<term>"` 看单条评分拆解、`rem-harness --path` 预览历史日记的 REM/Deep 输出、`rem-backfill --path`（可回滚）把历史日记回填成 `DREAMS.md` 条目或暂存候选。

## 会话上下文管理

- **会话键**：私聊默认共享一个主会话（`session.dmScope: "main"`，推荐多用户时改为 `per-channel-peer`）；群组按群隔离；每次 cron 运行新建会话。
- **存储**：活跃转录在 SQLite；`/new`、`/reset` 产生新 `sessionId`，旧转录不改写。`session.reset.mode` 默认 `"none"`（靠压缩管理增长），可选 `daily`（`atHour` 默认 4）或 `idle`（`idleMinutes`）。
- **压缩（compaction）**：`agents.defaults.compaction.enabled` 默认开；`mode` 新配置默认 `"safeguard"`（校验摘要结构、待办请求与精确标识符）；`keepRecentTokens` 默认 20,000；摘要输入上限 160,000 字符；每次压缩从上一次边界开始并带上上一份摘要；完整历史保留在磁盘。`/compact [focus]` 手动触发。
- **跨会话持久的内容**：转录、压缩摘要、工作区记忆文件。`/new` 清空对话但保留指令与工具；`memory.search.rememberAcrossConversations`（个人安装默认开）允许从同 Agent 的其他私有对话检索。
- **每回合组装**：指令文件 + 合格的 `MEMORY.md` / `USER.md`（预算内每回合刷新）+ 触发召回的 ≤ 3 条 + 可选 Active Memory 摘要 + 对话历史。日记与转录从不自动进入。

## 用户控制与隐私

- 记忆文件就是普通 Markdown，可直接编辑；文档建议放进**私有** git 仓库，并提供 `.gitignore` 起始项（`.env`、`**/*.key`、`**/*.pem`、`**/secrets*`），`~/.openclaw/`、SQLite 状态与 `credentials/` 不进仓库。
- Control UI 有 Dreams 标签页显示阶段状态、计数、下次运行与梦境日记；`/context list|detail`、`openclaw memory status [--deep]` 查看注入与索引状态。
- 关闭 / 调整：`dreaming.enabled`、`memoryFlush.enabled`、`openclaw hooks disable session-memory`、`memory.search.provider: "none"`（纯本地关键词模式，不向外发送嵌入请求）或 `local` / `ollama` / `lmstudio`（本地嵌入）。
- 导入时只复制 Markdown 记忆，不复制凭据、配置、会话、技能；冲突标记，替换前做校验备份。
- 隐身会话（Control UI "New thread"）仅驻内存、24 小时或网关重启后过期、不归档、不进搜索。
- 多用户网关：`tools.sessions.visibility` 默认 `"all"`，未隔离时用户之间共享上下文，文档要求用 `openclaw security audit` 检查。
- 风险点：`sessions_search` 节选不做凭据脱敏；默认嵌入 provider 是 OpenAI，意味着默认配置下记忆文本会发往外部服务做向量化。

## 已实现 / 实验性 / 仅规划

| 状态 | 内容 |
|---|---|
| 已实现 | Markdown 工作区（`MEMORY.md`、`USER.md`、日记）；SQLite FTS5 + 向量混合检索；固定规则排序（衰减、重要度、MMR）；`memory_search` / `memory_get`；来源类别与回合内污染；压缩前 memory flush；`session-memory` 钩子；Dreaming 三阶段与晋升门槛；`memory forget`；CLI 预览/回填/回滚；会话压缩与 `safeguard` 校验 |
| 实验性（文档明确标注） | PostgreSQL 记忆引擎；会话转录语义索引 `experimental.sessionMemory`；`memory-wiki` 的 `unsafe-local` 模式 |
| 可选插件 | `active-memory`（深度召回子 Agent）；`memory-wiki`（把持久记忆编译成带 claims / evidence / confidence 的 wiki vault，需 `openclaw plugins enable memory-wiki`）；`memory-lancedb`；Honcho 后端 |
| 未验证 | `session-memory` 钩子与 `active-memory` 插件是否默认启用；`USER.md` 元数据的字面语法；本地嵌入的具体性能 |

## 对 Amai 记忆层的借鉴点

1. **精选层与情景层之间的硬边界**：`MEMORY.md` / `USER.md` 永远只能通过门控整合或用户明确要求写入；日记可以随便追加但永远不自动注入。这直接对应 Amai 的 `summary.md` 与 `daily/` 的关系，并且解决了"抽取层输出无条件写进长期记忆"的风险。
2. **写入时记录来源，晋升由结构性前提控制**：`owner / agent / untrusted / system` 四类来源存在 Markdown 之外的索引列里，模型改不了。Amai 的感知数据天然是"观察事实"而非用户陈述，适合把来源类别扩展为 `observed`（感知）/ `user-stated` / `inferred`（模型推断）/ `external`，并规定只有 `user-stated` 与高置信 `observed` 能进 `summary.md`。
3. **按召回频率与查询多样性晋升**：Dreaming 不在写入时判断"重要"，而是看一条日记是否被不同问题反复召回。对环境感知场景尤其合适——每天会产生大量低价值观察，"被用到过"是比"模型觉得重要"更可靠的信号。
4. **固定规则包裹模型判断 + 可审阅的 `DREAMS.md`**：评分权重、阈值、最大删除比例（`maxPriorEntryLossFraction`）都是确定性代码，模型只做合并/取代决策且不输出替换正文；每次改写保留前像并写日记。Amai 的整合机制应采用同样的"可解释、可回滚、人类可读审计"结构。
5. **`USER.md` 原地取代而非追加**：偏好类信息带观察日期与 active / superseded 状态，变化时改写。Amai 的 `summary.md`、`goals/`、`health/` 中的稳定事实应遵循同一规则，避免矛盾条目堆积。
6. **派生索引与事实来源分离**：SQLite 只存索引、嵌入、来源、状态，`memory reset` 随时可清；Markdown 是唯一真相。与 AGENTS.md 中"辅助索引不替代 Markdown"一致。
7. **压缩前 flush 只允许追加新内容到日记，并拒绝整段回放**：防止上下文压缩时把转录原样倒进记忆。
8. **时间衰减只作用于带日期的日记文件，常青文件不衰减**：简单且与目录语义对齐。
9. **会话失败不阻塞主流程**：每个记忆步骤都有超时与回退。Amai 的抽取→记忆链路同样不能阻塞感知采集。

## 与 Amai 的差异及不采用的部分

| OpenClaw 做法 | Amai 的不同 / 不采用理由 |
|---|---|
| 输入是聊天消息，记忆写入由 Agent 在对话中决定 | Amai 输入是持续感知流，没有"对话回合"，写入决策应放在抽取层之后的独立整合流程，而非依赖 Agent 工具调用 |
| 默认嵌入 provider 为 OpenAI | 违反 Amai Privacy First；若采用向量检索应默认本地嵌入，远端必须显式开启 |
| 单一 `MEMORY.md` 作为长期记忆 | Amai 已确定按主题分目录（health / work / finance / goals），需要把"晋升"目标从单文件扩展为路由到专题文件 |
| 来源类别面向"谁说的"（owner / untrusted） | Amai 更需要"观察 / 陈述 / 推断"的认识论区分，二者可叠加但不能照搬 |
| 大量会话转录、cron、heartbeat、多 Agent、多渠道可见性等机制 | 与 Amai 无关的聊天平台复杂度，不引入 |
| Dreaming 依赖 Gateway 常驻进程与 cron 子系统 | Amai 应以更轻量的后台任务实现整合，不引入插件框架和 cron 基础设施 |
| `memory-wiki` 的 claims / evidence / confidence 模型 | 思路有价值（显式置信度、矛盾检测、陈旧页面报告），但过于重型，Amai MVP 阶段不采用，可作为后续 `summary.md` 质量检查的参考 |
| 通过 Active Memory 子 Agent 做多跳回忆 | 增加延迟与模型调用；Amai MVP 先做确定性检索，再评估是否需要 |

## 许可证与使用注意

- MIT 许可证，允许参考设计与引用思路；若直接复制代码需保留版权声明。AGENTS.md 要求不直接复制实现，本文仅描述设计。
- 项目体量巨大（11 万+ 提交、数百个扩展），作为依赖引入不现实；只借鉴记忆层设计。
- 文档版本漂移明显：同一功能在 docs.openclaw.ai、docs2 镜像、npm 内嵌 docs 之间描述不一致（如 Dreaming 默认开关、索引路径）。引用时应标注日期与页面。
- 仓库含 `security/`、`AGENTS.md`、`VISION.md` 等文件，调研安全设计时可进一步阅读（本次未读）。

## 来源

- https://github.com/openclaw/openclaw （README、目录结构）
- https://api.github.com/repos/openclaw/openclaw （许可证、星标、推送时间）
- https://api.github.com/repos/openclaw/openclaw/languages
- https://github.com/openclaw/openclaw/commits/main
- https://github.com/openclaw/openclaw/tree/main/extensions/memory-core
- https://github.com/openclaw/openclaw/tree/main/extensions/memory-core/src
- https://github.com/openclaw/openclaw/tree/main/src/memory
- https://docs.openclaw.ai/concepts/memory.md
- https://docs.openclaw.ai/concepts/memory-architecture.md
- https://docs.openclaw.ai/concepts/memory-builtin.md
- https://docs.openclaw.ai/concepts/memory-search.md
- https://docs.openclaw.ai/concepts/dreaming.md
- https://docs.openclaw.ai/concepts/agent-workspace.md
- https://docs.openclaw.ai/concepts/compaction.md
- https://docs.openclaw.ai/concepts/session.md
- https://docs.openclaw.ai/concepts/session-search.md
- https://docs.openclaw.ai/concepts/active-memory.md
- https://docs.openclaw.ai/concepts/active-memory/configuration.md
- https://docs.openclaw.ai/reference/memory-config.md
- https://docs.openclaw.ai/cli/memory.md
- https://docs.openclaw.ai/automation/hooks/bundled-hooks.md
- https://docs.openclaw.ai/plugins/memory-wiki.md
