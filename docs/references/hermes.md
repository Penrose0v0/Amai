# Hermes Agent

> 基本信息：
> - 地址：https://github.com/NousResearch/hermes-agent
> - 许可证：MIT（GitHub API `license.spdx_id = MIT`）
> - 主要语言/技术栈：Python（约 111 MB 源码，占绝对多数），TypeScript（约 39 MB，TUI / Web / Desktop 界面）；状态存储为 SQLite（WAL 模式 + FTS5，含自带 CJK 分词扩展 `native/fts5_cjk/`）
> - 活跃度（截至 2026-10-19）：约 255k stars、55k forks；仓库创建于 2025-07-22；`main` 分支最新提交日期为 2026-10-19，当天有十余次提交，极高活跃度
> - 本文调研日期：2026-10-19。官方文档站为 hermes-agent.nousresearch.com，部分页面已改版（如 `replace` 动作被移除），以当前页面与源码为准。

## 项目定位

Hermes Agent 是 Nous Research 推出的"自我改进"通用 Agent（"The agent that grows with you"）：可在本地或云端运行，接入多家模型提供方，通过 CLI / TUI / Telegram / Discord 等入口交互。它的差异化卖点是**学习闭环**——完成复杂任务后自动沉淀为技能（skills）、维护精简的个人记忆文件、并能对历史会话做全文检索。

与 OpenClaw 相比，Hermes 的记忆设计明显更"克制"：精选记忆只有两个小文件、硬性字符上限、无向量检索、无后台整合流程；它把"长篇知识"交给技能系统，把"历史细节"交给 SQLite 全文检索。

## 记忆系统概览

Hermes 官方文档把持久化能力分为四块，其中只有前两块被称为"记忆"：

| 组件 | 载体 | 注入方式 | 写入者 |
|---|---|---|---|
| 精选记忆 Curated memory | `MEMORY.md`（Agent 笔记）+ `USER.md`（用户画像） | 会话开始时整体渲染进系统提示词（冻结快照） | Agent 通过 `memory` 工具；后台 review；用户手动编辑 |
| 技能 Skills | `~/.hermes/skills/<category>/<name>/SKILL.md` | 按需加载（相关时才进入上下文） | Agent 通过 `skill_manage`；后台 review；用户 |
| 会话归档 Session archive | `~/.hermes/state.db`（SQLite + FTS5） | Agent 调用 `session_search` 时按需取回原文 | 运行时自动写入每条消息 |
| 外部记忆提供方 Memory providers | Honcho / Mem0 / RetainDB 等插件 | 注入 provider 上下文 + 每回合后台预取 | 每回合同步对话 |

设计上的核心取舍（源码 docstring 与文档原话概括）：

- 记忆"每回合都在上下文里"，所以必须小——用字符数而非 token 计量，上限写死在配置里。
- 会话开始时把记忆渲染成**冻结快照**，中途写入立即落盘但不改系统提示词，目的是保住模型侧的 prompt prefix cache。
- 没有 `read` 动作：记忆已在提示词中，不需要读。
- "Lessons, not logs"：记忆与技能都要求写结论，不写过程叙述。

## 存储格式与目录结构

默认 Hermes home 为 `~/.hermes`（Windows 为 `%LOCALAPPDATA%/hermes`），使用命名 profile 时为 `~/.hermes/profiles/<name>/`，各 profile 的记忆与数据库互不共享。

| 路径 | 内容 | 上限 |
|---|---|---|
| `~/.hermes/memories/MEMORY.md` | Agent 个人笔记：环境事实、约定、教训、已完成工作 | `memory.memory_char_limit` 默认 2,200 字符（约 800 token） |
| `~/.hermes/memories/USER.md` | 用户画像：身份、时区、沟通偏好、技术水平、忌讳 | `memory.user_char_limit` 默认 1,375 字符（约 500 token） |
| `~/.hermes/memories/*.lock`、`*.bak` | 写锁文件（owner-only 权限）与检测到外部漂移时的备份 | — |
| `~/.hermes/SOUL.md` | 人格与语气（仅从 home 加载，非记忆） | — |
| `~/.hermes/skills/**/SKILL.md` | 技能，YAML frontmatter（`name`、`description`、`version`、`platforms`、`metadata.hermes.*`） | 正文超过约 24k 字符会被 linter 警告（不阻止） |
| `~/.hermes/pending/skills/`（及记忆对应目录） | 待审批的暂存写入 | — |
| `~/.hermes/state.db`（+ `-wal`、`-shm`） | 会话、消息、FTS 索引、压缩锁、运行账本等 | schema version 31 |

**`MEMORY.md` / `USER.md` 的文件格式**（来自 `tools/memory_tool_store.py` 的设计）：

- 纯 UTF-8 文本，条目之间用单独一行的分节符 `§` 分隔；读取时去空白、丢弃空条目。
- **没有 frontmatter，没有逐条时间戳，没有来源字段**。唯一的时间信息是漂移备份文件名。
- 渲染进系统提示词时每个存储块上下各一条 46 字符的分隔线，标题为 "MEMORY (your personal notes)" 或 "USER PROFILE (who the user is)"，附一行用量 `NN% — current/limit chars`，空存储不渲染。
- 如果文件中存在单条超过整个存储上限的条目（说明用户手工写了无分隔的大段文字），写入被拒绝并保存 `.bak`。

`state.db` 主要表：`sessions`（含 `id`、`source`、`user_id`、`model`、`system_prompt` 哈希引用、`parent_session_id`、`title`、token / 成本列、`archived` / `auto_archived` / `pinned`）、`messages`（`role`、`content`、`tool_calls`、`timestamp`、`token_count`、`active`、压缩摘要列等）、`system_prompts`（按 SHA-256 去重存储）、`messages_fts`（索引 `content`、`tool_name`、`tool_calls`）、`messages_fts_trigram`（CJK / 子串）、`messages_fts_cjk`（`cjk_unicode61` 分词器）、`state_meta`、`compression_locks` 等。

## 写入机制

**`memory` 工具**（`tools/memory_tool.py`，toolset `memory`）：

- 必填 `target`：`"memory"` 或 `"user"`，每次调用只能写一个存储；运行时按已启用的存储收窄。
- 动作：`add`（新增）、`patch`（在一条条目内替换唯一子串 `old_text` → `content`）、`remove`（按唯一子串删除）。`replace` 已从 schema 移除，调用会报错并指向 `patch`（仅为回放旧的暂存写入而保留识别）。
- 批量：`operations` 列表原子应用，只在**最终状态**检查字符上限——因此一次批量可以"删旧腾空间 + 加新"。超限错误会返回 `current_entries` 与需释放的字符数，要求 Agent 在同一回合内整理后重试。**没有自动压缩或自动淘汰**。
- 去重：加载与每次加锁写入时按**精确匹配**去重（保留首个）；`add` 遇到完全相同内容返回成功但不新增。定位条目时使用归一化匹配（弯引号 / 反引号折叠为直引号、破折号变体折叠、空白合并），但归一化**不用于去重**——语义改写的重复不会被识别。
- 歧义：`patch` / `remove` 的子串匹配多条时报错；匹配不到时返回最多 3 条 `closest_entries`（按 `old_text` 的词覆盖率 ≥ 0.3 排序）。
- 并发安全：`.lock` 文件 + `fcntl` / `msvcrt` 锁，锁内重读、检查漂移、改写临时文件后原子重命名；旧文件读不出时拒绝写入，避免用空视图覆盖真实内容。文档要求同一 Hermes home 只能有一个写入进程。
- 安全扫描：每条新增 / 修补内容先经 `_scan_memory_content`（共享的威胁模式模块，覆盖提示注入与凭据外泄模式；文档称还阻止不可见 Unicode——该规则在源码摘录中未见，未验证）。批量中任一条被标记则整批拒绝。加载时被标记的条目在提示词快照中替换为占位符，但磁盘保留原文供用户审查删除。

**谁决定写什么**：

1. **Agent 在对话中主动写**：工具描述与系统提示词给出路由规则——用户偏好 → `user`；环境事实、约定、纠正、已完成工作、用户说"记住" → `memory`；可重复的多步流程 → 技能（`skill_manage`），不占记忆预算。要求跳过琐碎、易重新发现、原始日志 / 大段代码、会话临时信息、已在 `SOUL.md` / `AGENTS.md` 里的内容。一条事实只能进一个存储。
2. **周期性提醒（nudge）**：`memory.nudge_interval` 每 N 个回合提示 Agent 保存记忆，默认值在官方配置页截断部分未读到；社区指南与插件页显示默认约为 10 回合、0 为关闭（未验证）。源码测试 `test_memory_nudge_counter_hydration.py` 显示实现是 `_turns_since_memory >= _memory_nudge_interval` 计数器，并需从历史恢复计数以免网关重建 Agent 后永不触发。`skills.creation_nudge_interval` 对技能同理。
3. **后台自我改进 review**（`agent/background_review.py`）：一个回合结束后在守护线程中 fork 一个 Agent 重放对话，决定是否写记忆或新增 / 更新技能。默认复用父 Agent 的模型与缓存的系统提示词以命中 prefix cache；若 `auxiliary.background_review.model` 指向其他模型则把旧回合折叠成摘要。工具白名单仅含记忆 / 技能管理与只读文件工具；最多 16 次迭代；输入 token 预算默认为上下文窗口的 75%（上限 600k）；新的用户回合或会话结束会取消它（最多等 2 秒）。无人值守的 review **只能 `add`**，其 `patch` / `remove` 一律暂存待审批。用户可用 `/refine [focus]` 显式触发。
4. **写审批**：`memory.write_approval`（默认 `false`）为 `true` 时，CLI 回合内联询问，消息平台与后台 review 的写入暂存，通过 `/memory pending|approve <id|all>|reject <id|all>|approval on|off` 处理。暂存的 `patch` / `remove` 会"钉住"当时匹配到的完整条目，审批前条目若被改动则拒绝应用。
5. **用户手动编辑**：直接改文件即可，写入时检测外部漂移并备份。

**事实 vs 推断**：没有任何字段或约定区分。仅有的分层是 `memory`（环境）与 `user`（画像）两个存储，以及"写结论不写日志"的提示词约束。

## 检索与索引

**精选记忆**：不检索，全量注入。这是 Hermes 把上限压到 3,575 字符的直接原因。

**会话搜索（`session_search` 工具，toolset `session_search`）**：

- 后端是 `hermes_state.py` 的 `search_messages()`：FTS5 查询语法（隐式 AND、引号短语、`OR`、`NOT`、前缀 `*`），输入经清洗（连字符词自动加引号）；支持 `source_filter`、`exclude_sources`、`role_filter`。
- 四种调用形态：`query`（发现）、`session_id` + `around_message_id`（滚动）、仅 `session_id`（通读）、无参数（浏览）；发现模式支持 `after` / `before` 时间界（ISO 日期或 `7d`、`24h`、`2w`）与 `exclude_session_ids`（迭代排除）。
- 返回字段：`id`、`session_id`、`role`、`timestamp`、带 `>>>match<<<` 标记的 `snippet`、`context`（前后各 1 条，截断 200 字符）、`source`、`model`、`session_started`。
- 工具参考页明确："FTS5-backed retrieval, returns actual stored messages with no LLM calls"。README 中"FTS5 session search with LLM summarization for cross-session recall"的说法与当前工具页矛盾，可能是旧版行为或由 Agent 自行总结（未验证）。
- 索引范围：FTS 由 INSERT / UPDATE / DELETE 触发器同步维护；增量 merge 而非全量 optimize，避免长时间持锁；cron 与子 Agent 会话已从 trigram 表移除但仍在主 FTS 表。
- 没有向量 / 嵌入检索，没有混合排序，没有时间衰减（仅时间过滤）。

**技能**：按需加载；`skills.auto_load` 列出的技能常驻系统提示词且不被压缩；一次斜杠命令最多加载 5 个技能。

**外部 provider**（可选，`memory.provider`，同一时间只能激活一个）：激活后每回合（1）把 provider 上下文注入系统提示词，（2）回合前后台非阻塞预取相关记忆，（3）回合后同步对话，（4）会话结束时提取记忆（支持的 provider），（5）把内置记忆写入镜像到 provider，（6）增加 provider 专属工具。Honcho 提供 `honcho_context`（辩证式问答，用 Honcho 侧 LLM）、`honcho_profile`、`honcho_search`。内置 `MEMORY.md` / `USER.md` 始终保留（"additive"）。

**Token 预算**：记忆侧靠字符上限；上下文文件（`AGENTS.md` 等）上限 `context_file_max_chars`，未设时按模型窗口在 20,000–500,000 字符间缩放，超限保留头 70% + 尾 20%；后台 review 有独立 token 预算。

## 整合、摘要与遗忘

Hermes **没有**后台整合 / 晋升 / 遗忘流程。相关机制只有：

- **人工驱动的整理**：记忆用量超过 80% 时提示词建议 Agent 合并相关条目；超限时强制在同一回合内用批量操作腾空间。这是"由上限倒逼的即时整合"，而非周期性任务。
- **后台 review**：如上所述，是"会话后一次性的提取"，不读取历史记忆做跨会话合并（它只能 `add`，修改需审批）。
- **会话压缩（context compression）**：属于上下文管理而非记忆整合，见下一节；压缩掉的消息软归档（`active=0, compacted=1`）仍可被 `session_search` 命中。
- **会话清理**：`prune_sessions(older_than_days, source)` 只删除已结束会话；`delete_session` 删会话与消息，但运行账本表 `ON DELETE RESTRICT`，有在途工作时拒绝；`sessions.auto_archive` 驱动空闲归档（默认阈值未在文档中给出）。
- **`hermes journey`**（别名 `learning`、`memory-graph`）：按时间线展示学到的技能与记忆条目，支持 `list`、`delete <node>`、`edit <node>`——这是一种可视化的手动遗忘。

没有时间衰减、没有置信度、没有矛盾检测。

## 会话上下文管理

每回合系统提示词组成：`SOUL.md` → 项目上下文文件（按 `.hermes.md` / `AGENTS.override.md` / `AGENTS.md` / `CLAUDE.md` / `.cursorrules` 顺序取首个匹配，git 仓库内从根到工作目录链式叠加）→ `MEMORY.md` / `USER.md` 冻结快照 → provider 上下文 → 自动加载技能 → 对话历史。工具调用触及新目录时，子目录的 `AGENTS.md` 等以 ≤ 32,000 字符的提示附加到工具结果里。

**上下文压缩**（`agent/context_compressor.py`，可通过 `context.engine` 换成插件引擎，`ContextEngine` ABC 定义 `should_compress()` / `compress()`）：

| 配置 | 默认 | 含义 |
|---|---|---|
| `compression.enabled` | `true` | |
| `compression.threshold` | `0.50` | 提示 token 达到窗口该比例时触发；窗口 < 512K 时下限 0.75 |
| `compression.threshold_tokens` | `null` | 可选绝对上限，取二者较小 |
| `compression.protect_first_n` | `3` | 保护系统提示与首轮交换 |
| `compression.protect_last_n` / `tail_mode` | `20` / `lean` | 尾部最少保留条数；lean 模式保留约窗口 2.5%（10K–25K token） |
| `compression.in_place` | `true` | 同一 session id 内软归档；`false` 时新建会话并以 `parent_session_id` 链接 |
| `auxiliary.compression.model` | 空（用主模型） | 摘要模型，其窗口必须 ≥ 主模型 |

摘要走固定模板（Goal / Constraints / Progress(Done, In Progress, Blocked) / Key Decisions / Relevant Files / Next Steps / Critical Context），预算为内容的 20%（2,000 token 下限，上限取 5% 窗口与 12,000 较小者），后续压缩在上一份摘要上更新。压缩前先把 > 200 字符的旧工具输出替换为占位符（无 LLM 调用）。网关侧另有 85% 的"卫生层"兜底（`gateway/run_turn_hygiene.py`）。**文档未描述压缩前的记忆保存提醒**（与 OpenClaw 的 memory flush 不同）。

**跨会话持久**：`state.db` 中的完整转录与软归档、`MEMORY.md` / `USER.md`、技能、`context_length_cache.yaml`、压缩失败冷却计时。会话标题最长 100 字符，带来源等级（derived / LLM 生成 / 用户设置），自动起名只能覆盖低等级标题。

## 用户控制与隐私

- 记忆文件为纯文本，可直接编辑；`/memory` 系列命令管理待审批写入；`hermes journey` 查看 / 删除 / 编辑学习节点；`hermes sessions list|export|prune|rename|delete`；`hermes backup`（`--quick` 只备份 config.yaml、state.db、.env、auth、cron）。
- `display.memory_notifications`：`off | on（默认）| verbose`，控制记忆写入在聊天中的提示；可按平台覆盖。
- 开关：`memory.memory_enabled`、`memory.user_profile_enabled` 同为 `false` 时移除内置工具；`memory.nudge_interval: 0` 关闭提醒；`agent.disabled_toolsets` 可禁用 `session_search`。
- 本地优先：内置记忆与会话搜索完全本地、无 LLM 调用；`state.db` 及 WAL 文件以 owner-only 权限创建；profile 之间隔离。
- 外部 provider 的数据边界：发送给 provider 的所有内容（回合、工具输出、召回查询、镜像写入等）先经密钥扫描脱敏，"即使 `security.redact_secrets: false`"；但无法识别形状的凭据不会被检测，本地转录保留原文。多数 provider 为云服务（Honcho Cloud、Mem0 Platform 等），文档列出本地 / 自托管替代（Holographic 仅本地 SQLite、ByteRover 默认本地、Mem0 OSS 等），并提醒 mem0ai SDK 默认发送 PostHog 遥测（`MEM0_TELEMETRY=false` 关闭）。
- 风险点：`session_search` 返回原始消息，不做脱敏；`MEMORY.md` 无时间戳与来源，无法追溯一条记忆何时、因何写入。

## 已实现 / 实验性 / 仅规划

| 状态 | 内容 |
|---|---|
| 已实现 | 双文件精选记忆与字符上限；`memory` 工具（add / patch / remove、批量、去重、安全扫描、锁与原子写）；冻结快照；写审批与暂存；周期性 nudge；后台自我改进 review；技能系统与 `skill_manage`；SQLite + FTS5 会话搜索（含 CJK 分词）；上下文压缩与可插拔 `ContextEngine`；8 个外部 memory provider 插件；`hermes journey` |
| 过渡中 | RetainDB 与 ByteRover 原为内置 provider，文档称"于 2026-10-15 离开核心"，其独立仓库已不维护（当前打包状态未验证） |
| 实验性 | 文档未明确标注任何记忆相关功能为实验性 |
| 未验证 / 文档不一致 | `nudge_interval` 官方默认值；`session_search` 是否有 LLM 总结（README 与工具页矛盾）；不可见 Unicode 阻断规则的具体实现；`sessions.auto_archive` 默认阈值；`memory.prefetch_spill_enabled` 的含义 |
| 仅规划 | 未在官方文档中发现记忆层的路线图条目 |

## 对 Amai 记忆层的借鉴点

1. **给"常驻上下文"的记忆设硬性字符预算，并把溢出处理交给写入者**：超限即报错、要求同回合整理。这保证 `summary.md` 之类"每次都加载"的文件不会无限膨胀，比靠截断注入更可控。Amai 的 `summary.md` 应有明确的预算，整合流程必须在预算内重写。
2. **写入即扫描**：任何会进入系统提示词并跨会话持久的内容，在落盘前做提示注入 / 凭据模式检查；被标记的条目在注入时替换占位符但磁盘保留以供人审。对 Amai 尤其重要——屏幕 OCR 与音频转录天然可能携带密码、token 与第三方文本。
3. **批量原子写 + 只校验最终状态**：允许"删旧加新"在一次事务内完成，配合文件锁、漂移检测、临时文件原子重命名、读不出就拒写。Amai 的 Markdown 写入层应采用同样的安全写入原语。
4. **暂存 / 审批与"钉住"语义**：破坏性修改（patch / remove）可以暂存等待用户确认，且审批对象是当时看到的完整条目，被改过就拒绝应用。Amai 对 `summary.md`、`health/`、`finance/` 等敏感专题文件的自动修改可以默认走审批。
5. **长流程归技能、小事实归记忆的分工**：Hermes 用"是否每回合都需要"作为分流标准，而不是把一切塞进一个文件。对应到 Amai：`summary.md` 只放稳定事实，细节放专题文件与 `daily/`，按需检索。
6. **会话 / 原始记录与精选记忆彻底分离**：历史明细只进 SQLite FTS，按需精确召回，不做语义化"二次记忆"。Amai 的抽取层输出（短时窗口上下文）可以类似地只做本地全文索引而不自动提升。
7. **后台 review 的权限收缩**：无人值守流程只能新增、不能改删；被新的前台活动打断时让路。这是 Amai 后台整合任务的一个合理安全默认。
8. **冻结快照换取缓存稳定**：对调用外部 LLM 的 Amai 组件（抽取与整合）同样适用——同一批次内固定上下文前缀，可显著降低成本。

## 与 Amai 的差异及不采用的部分

| Hermes 做法 | Amai 的不同 / 不采用理由 |
|---|---|
| 只有两个精选文件、3,575 字符总预算 | Amai 需要按主题的多文件长期记忆（health / work / finance / goals / daily），不能把一切压进两个文件；但"每个常驻文件有预算"的原则保留 |
| 记忆条目无时间戳、无来源、无置信度 | 违反 Amai 的 Traceable 原则与"区分观察 / 陈述 / 推断"要求；Amai 条目必须带时间范围、来源模态与置信信息 |
| 无后台整合、无衰减、无遗忘 | Amai 持续产生感知数据，`daily/` 必须有向专题文件与 `summary.md` 滚动汇总的机制，否则无法形成长期理解 |
| 写入决策完全依赖 Agent 在对话回合中调用工具 + 回合计数 nudge | Amai 没有"对话回合"，写入应由抽取层事件驱动的整合流程决定 |
| 检索仅限会话全文（FTS5），精选记忆全量注入 | Amai 的 Retrievable 原则要求按问题检索专题 Markdown，至少需要对 Markdown 做 FTS 索引；是否引入向量检索待评估 |
| 技能系统、多平台网关、provider 插件生态 | 与 Amai 无关，不引入 |
| 外部 provider 把对话同步到云端 | 与 Privacy First 冲突；若未来需要外部记忆服务，必须显式开启并经脱敏 |
| 用 Python + 单体 `hermes_state.py` 管理所有状态 | Amai 技术栈未定，不以此为依据选择语言；SQLite + FTS5 作为本地索引后端的选择本身值得参考 |

## 许可证与使用注意

- MIT 许可证，可自由参考设计；复制代码需保留版权声明。本文仅描述设计，不含代码。
- 仓库体量大（5.6 万+ 提交，单日十余次合并），`replace` → `patch` 这类接口变更说明文档与源码可能在数周内失效；引用时应标注日期。
- 官方文档站的多个页面超过 WebFetch 的 10 万字符截断（配置参考、CLI 参考），本文标注"未验证"的默认值来自未读到的部分或社区资料。
- `native/fts5_cjk/` 是 Hermes 自带的 FTS5 CJK 分词扩展，若 Amai 采用 SQLite FTS5 处理中文内容，可研究其许可证与实现方式作为参考（本次未读源码）。

## 来源

- https://github.com/NousResearch/hermes-agent （README、目录结构）
- https://api.github.com/repos/NousResearch/hermes-agent （许可证、星标、推送时间）
- https://api.github.com/repos/NousResearch/hermes-agent/languages
- https://github.com/NousResearch/hermes-agent/commits/main
- https://github.com/NousResearch/hermes-agent/tree/main/tools
- https://github.com/NousResearch/hermes-agent/tree/main/agent
- https://raw.githubusercontent.com/NousResearch/hermes-agent/main/tools/memory_tool.py
- https://raw.githubusercontent.com/NousResearch/hermes-agent/main/tools/memory_tool_store.py
- https://raw.githubusercontent.com/NousResearch/hermes-agent/main/hermes_state.py
- https://raw.githubusercontent.com/NousResearch/hermes-agent/main/agent/background_review.py
- https://hermes-agent.nousresearch.com/docs/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers
- https://hermes-agent.nousresearch.com/docs/user-guide/features/skills
- https://hermes-agent.nousresearch.com/docs/user-guide/features/tools
- https://hermes-agent.nousresearch.com/docs/user-guide/features/context-files
- https://hermes-agent.nousresearch.com/docs/user-guide/configuration （前 10 万字符）
- https://hermes-agent.nousresearch.com/docs/developer-guide/session-storage
- https://hermes-agent.nousresearch.com/docs/developer-guide/context-compression-and-caching
- https://hermes-agent.nousresearch.com/docs/reference/tools-reference
- https://hermes-agent.nousresearch.com/docs/reference/cli-commands （前 10 万字符）
- 辅助（非权威，仅用于交叉核对 nudge 默认值）：https://mem0.ai/blog/how-memory-works-in-hermes-agent-(and-how-to-improve-it) 、搜索结果中引用的 `tests/run_agent/test_memory_nudge_counter_hydration.py`
