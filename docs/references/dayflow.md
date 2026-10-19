# Dayflow

> 基本信息（截至 2026-10-19）
>
> | 项目 | 内容 |
> |---|---|
> | 地址 | https://github.com/JerryZLiu/Dayflow （官网 https://www.dayflow.so/） |
> | 许可证 | MIT（SPDX: `MIT`），无双许可、无商业限制 |
> | 主要语言 / 技术栈 | Swift（SwiftUI + AppKit），Xcode 工程；ScreenCaptureKit、AVFoundation、GRDB（SQLite）、Sparkle、Sentry、PostHog |
> | 活跃度 | 7,288 stars / 445 forks；仓库创建于 2025-09-23；最近推送 2026-10-19（当日发布 v2.7.2，build 136）；约 2,200 次提交；107 个 open issues（含 PR） |
> | 平台要求 | macOS 14+，Apple Silicon 优先；需要「屏幕与系统音频录制」权限 |
> | 安装 | GitHub Releases DMG、`brew install --cask dayflow`、源码 Xcode 构建 |

## 项目定位

Dayflow 自我定义为「a private, automatic work journal for Mac」——一个本地优先的自动工作日志 / 时间追踪器。它周期性截取屏幕，将截图交给 VLM 分析，把一天压缩为一串「活动卡片（activity cards）」时间线，并在此之上提供每日站会摘要、周回顾、分心追踪、对日志的自然语言问答，以及 Markdown 导出。

与 Amai 的关系：Dayflow 是一个**面向单一产出（时间线）的个人工作日志产品**，而不是通用的环境感知基础设施。它只覆盖视觉模态（不录音频、不记录键鼠内容），抽取结果是「活动卡片」而非通用语义记忆。它最值得参考的是：macOS 上**低侵入的截图式感知**、**以 15 分钟为单位的批处理 + VLM 抽取**、以及**可替换的多 LLM Provider 设计**。

## 架构概览

Dayflow 是单进程 macOS 应用（一个 `.app`，带菜单栏图标和主窗口），没有独立 daemon。所有采集、分析、存储、UI 都在同一进程中，由 `AppDelegate` 在启动时拉起各服务。

| Amai 层 | Dayflow 对应 | 主要代码位置（`Dayflow/Dayflow/`） |
|---|---|---|
| 感知层 | `ScreenRecorder`（ScreenCaptureKit 截图定时器）→ `FrameStore`（HEVC 分段编码）→ `screenshots` 表 | `Core/Recording/ScreenRecorder.swift`、`FrameStore.swift`、`ScreenCaptureMonitor.swift`、`RecordingPrivacyPreferences.swift` |
| 抽取层 | `AnalysisManager`（每 60s 扫描未处理截图，切成 15 分钟批次）→ `LLMService`（Provider 路由）→ 各 Provider 的「transcribe（观察）→ generate cards（卡片）」两步或 one-step | `Core/Analysis/AnalysisManager.swift`、`IdleBatchClassifier.swift`、`Core/AI/*`（79 个文件） |
| 记忆层 | SQLite（GRDB）中的 `observations`、`timeline_cards`、`daily_standup_entries`、`day_goals`、`chat_*` 等表；Markdown 仅作为导出格式 | `Core/Recording/StorageManager*.swift`、`Core/AI/DailyRecapGenerator.swift`、`Core/Weekly/` |
| 对外接口 | `dayflow` CLI + MCP server（只读直接查 SQLite；写操作走 Unix socket `agent.sock`） | `Core/AgentAccess/AgentBridgeServer.swift`、`tools/dayflow-cli/` |

数据流：截图（每 10s）→ HEVC 分段文件 + `screenshots` 行 → 每 60s 聚合为 ≥5 分钟、目标 15 分钟的 `analysis_batches` → 空闲批次直接写 Idle 卡片，否则调用 LLM → `observations`（带时间戳的观察文本）→ `timeline_cards`（10–60 分钟一张，允许与前一张合并）→ UI / 站会 / 周报 / 聊天。

注意 Dayflow **没有真正意义上的「长期记忆层」**：卡片即最终产物，没有跨天的整合、遗忘或用户档案机制（`DashboardChatMemoryStore.swift` 仅用于聊天上下文，未深入验证）。

## 感知层实现细节

### 屏幕采集

| 项目 | 实现 |
|---|---|
| API | **ScreenCaptureKit 的 `SCScreenshotManager.captureImage(contentFilter:configuration:)`**，一次一帧；不使用 `SCStream` 持续流，也不使用 `CGDisplayStream` / `CGWindowListCreateImage`。源码注释说明改用截图模式是为了**避免 macOS 的「屏幕录制中」橙色指示器**。 |
| 频率 | `ScreenshotConfig.interval` 默认 **10 秒**，可选 1/5/10/20/30/60 秒（`RecordingPreferences.swift`）。用 `DispatchSourceTimer` 驱动；上一帧未完成时跳过本次 tick（`captureInFlight`）。 |
| 分辨率 | 目标高度默认 **1080px**，可选 720px；按显示器宽高比缩放并取偶数（便于视频编码）；`scalesToFit = true`、`showsCursor = true`。 |
| 多显示器 | 只录**一个**显示器：优先用户指定 → `ActiveDisplayTracker` 判定的活动显示器 → `SCShareableContent` 的第一个。显示器变化通过 `NSApplication.didChangeScreenParametersNotification` 触发 2s 延迟的合并刷新。 |
| 空闲 | 不暂停采集；每帧附带 `idleSecondsAtCapture`，取自 `CGEventSource.secondsSinceLastEventType`（HID 系统状态、任意输入事件类型）。空闲判定推迟到抽取层做（见下文）。 |
| 睡眠/锁屏 | `NSWorkspace.willSleep`、`com.apple.screenIsLocked`、`com.apple.screensaver.didstart` → 停止并标记 `.paused`；对应的唤醒/解锁/屏保结束事件 → 延迟 5s 恢复。 |
| 失败恢复 | 捕获失败退避 `[60,120,300,600]` 秒；初始化失败重试 `[5,30,60,120,300,600]` 秒；连续失败 10 分钟后若权限仍显示已授予则关闭录制并弹出权限提示。成功后清零失败计数。 |
| 音频 | **不采集**。`SCStreamConfiguration` 未开启音频。`NSMicrophoneUsageDescription` 仅用于 "Flow" 功能的语音对话。 |
| 键鼠 | **不记录内容**。只用 `CGEventSource` 读取「距上次输入多少秒」；`InactivityMonitor` 用进程内 `NSEvent` 本地监视器判断应用内空闲（默认 15 分钟）以决定是否重置 UI，不涉及录制。 |

### 帧存储（感知层输出格式）

`FrameStore.swift` 把每帧 `CGImage` 追加进 **HEVC/MP4 分段**，而不是逐帧存图片：

- 每段最长 600 秒或 600 帧（`segmentDuration = 600`、`maxFramesPerSegment = 600`），关键帧间隔 30 帧；帧 N 的呈现时间为 N 秒（假定约 1 fps）。
- `encodeQuality = 0.55`（注释：「能让小号 UI 文字保持可读的最低设置」）；不支持质量模式的编码器回退到约 2 Mbps@1080p、下限 500 kbps。
- 尺寸变化时自动切新段；停止/睡眠/锁屏/退出时 `finishCurrentSegment()`。
- 每帧在 `screenshots` 表写一行（`file_path` 指向段文件、`frame_index`、`captured_at`、`idle_seconds_at_capture`、`file_size`）；段最终化后把总字节数均分到各帧行，便于按行做容量核算。
- 启动时 `reconcileAfterLaunch` 检查最后一段是否可读，不可读则删除。
- 实测估算：10 秒间隔下约 **5 MB/小时（≤720p）或 10.3 MB/小时（1080p）**（代码内注释，HEVC）。
- 没有帧去重：所有帧都编码。

`ScreenCaptureMonitor.swift` 是一个遥测用的监视器（针对 issue #381「权限已授予但截图失败」）：统计 SCK 请求次数、检测 60 秒内 ≥10 次 `SCShareableContent` 调用的突发、在失败时用 `CGPreflightScreenCaptureAccess()` 判断权限是否仍完好，并通过 `isCaptureBlocked` 暴露锁屏/睡眠状态。

## 抽取层实现细节

### 批处理与调度（`AnalysisManager.swift`）

- 每 **60 秒**一次扫描；只看最近 24 小时的未处理截图。
- 按 `BatchingConfig.standard`：**目标时长 15 分钟（`targetDuration = 15*60`）**，截图间隔超过 **2 分钟（`maxGap = 2*60`）** 即切批。最后一批不足 15 分钟则等待。
- 批次跨度 < 300 秒 → `skipped_short`；无截图 → `failed_empty`。
- **空闲短路**（`IdleBatchClassifier`）：仅依赖每帧的 `idleSecondsAtCapture`，不比较帧内容。批次 ≥12 分钟、空闲区间覆盖 ≥95%、无 >30s 的未覆盖间隙、≥90% 的帧空闲 ≥60s 时直接生成「Idle」卡片，不调用 LLM；相邻空闲卡片间隙 <5 分钟则合并。
- 串行队列 `com.dayflow.geminianalysis.queue`（`.utility` QoS），`isProcessing` 防重入；每批最多自动重试 3 次，成功后触发对失败批次的追赶处理。
- 状态机：`processing / completed / analyzed / failed / failed_empty / skipped_short`，存于 `analysis_batches`。
- 支持按天 / 按批次手动重跑（删除 observations 与卡片后重排队）。

### Provider 抽象（`LLMService.swift`、`LLMTypes.swift`）

协议 `LLMServicing`：`processBatch`、`generateText`、`generateTextStreaming`、`generateChatStreaming`、`batchingConfig`。Provider 枚举 `LLMProviderID`：`dayflow`（官方云后端）、`gemini`、`chatgpt`（Codex CLI）、`claude`（Claude Code CLI）、`openai_compatible`、`local`（Ollama / LM Studio）。

支持主备两个 Provider（`LLMProviderRoutingStore`）：主 Provider 失败后对备用 Provider 尝试一次；Gemini 失败后自动降级到 `GemmaBackupProvider`（云端 `gemma-4-31b-it`，仍走 Google API）并保持。时间线重写由共享 gate 串行化，失败批次生成一张带说明文字的错误卡片。

### 两步抽取：Observations → Activity Cards

| Provider | 输入形式 | 第一步（transcribe → `observations`） | 第二步（cards） |
|---|---|---|---|
| Gemini 直连 | 把批次截图合成 **1 fps H.264 MP4（≤720p，约 1.2 Mbps）**，通过 Files API 上传后作为 `file_data` 引用 | 提示词要求输出 3–8 段 JSON（`startTimestamp/endTimestamp/description`，MM:SS），要求读菜单栏得到应用名、记录文件名/URL/用户名等细节；用 response schema 约束；`thinkingLevel: high`、输出上限 65,536 token；120s 超时；每批最多 3 次尝试，容量错误（403/404/429/503）立即换下一个模型 | 把观察文本 + 既有卡片 JSON 一起喂给模型，要求「以本人记笔记的口吻」输出卡片；卡片 10–60 分钟、意图持续变化 ≥10 分钟才开新卡、<5 分钟的岔开记为 `distractions`；允许改写/合并之前的卡片；时间覆盖校验（±3 分钟）失败则带错误反馈重试，最多 4 次 |
| 本地（Ollama/LM Studio，OpenAI 兼容） | 从批次中按 stride 抽约 **15 帧**，每帧 JPEG（≤720p，质量 0.85）base64 | **逐帧**让 VLM 用 1–2 句描述（`describe_frame`），再把 `[MM:SS] 描述` 列表喂给文本模型合并为 **2–5 段**（`segment_video_activity`，JSON，覆盖率 ≥80%，最多 2 次）；失败则退化为「一帧一观察」 | 「两遍法」：先生成标题/摘要，再判断是否与上一张卡合并（上张 ≥40 分钟不合并、间隙 >5 分钟新开、合并后 >60 分钟新开） |
| Claude Code / Codex CLI | 把抽样帧拼成 **5×3 联系表（contact sheet）**，附时间戳元数据和 **Apple Vision OCR 提示**（作为可能出错的辅助） | 通过本地 CLI 子进程、`sonnet`、低推理强度，最多 3 次会话内重试 | 同上风格 |
| Dayflow 云后端 | 最多 15 帧 JPEG base64（转写 720p、时间线 1080p） | `/v1/dayflow/transcribe` | `/v1/dayflow/generate-cards`，或 `/v1/dayflow/generate-timeline` 一步到位（180s 超时） |

推荐的本地模型（`LocalModelPreset.swift`）：**Qwen3-VL 4B**（`qwen3-vl:4b`，约 5 GB，推荐）、Qwen2.5-VL 3B（旧默认）。要求 Ollama ≥0.12.10 或 LM Studio 0.3.31。Gemini 模型级联默认 `gemini-3.8-flash → 3.7 → 3.6 → 3.5 → 3.5-flash-lite`。

**One-step 模式**（`OneStepTimelineSupport.swift`）：支持的 Provider 先尝试「截图 → 卡片」一步生成，再从卡片明细行反推 observations；失败才退回两步。

**OCR**：Dayflow 不把 OCR 作为主抽取手段，只在 Claude/Codex 路径中用 Apple Vision 生成提示文本（`AgentCLISupport+Transcription.swift`，具体 Vision 调用未逐行验证）。

### 下游产物

- `DailyRecapGenerator`/`DailyRecapScheduler`：每日站会（昨日亮点、今日优先级、阻塞）。
- `Core/Weekly/`：周回顾。
- `ChatService` + `DashboardChat*`：对时间线的问答与工具调用（Gemini 流式或 Claude/Codex CLI）。
- `Core/Flow/`：专注会话（Flow）功能，含分心检测 Agent 与覆盖层；2026-10 的提交几乎全部围绕它和菜单栏 UI。

## 存储与资源管理

| 项目 | 实现 |
|---|---|
| 数据库 | SQLite，经 **GRDB `DatabasePool`**（跟踪 master 分支，未锁版本）；WAL、`synchronous=NORMAL`、5 个 reader、5s busy timeout；每 300s checkpoint；每日备份保留最新 3 份 |
| 位置 | `~/Library/Application Support/Dayflow/`：`chunks.sqlite`、`recordings/`（HEVC 段，文件名 `yyyyMMdd_HHmmssSSS.mp4`）、`timelapses/<日期>/`、`backups/`、`agent.sock`、`agent-writes.log` |
| 主要表 | `screenshots`、`analysis_batches`、`batch_screenshots`、`observations`、`timeline_cards`、`timeline_review_ratings`、`daily_standup_entries`、`day_goals`、`llm_calls`（记录每次 LLM 请求/响应）、`chat_conversations/messages`；旧的 `chunks`/`batch_chunks`/`journal_entries` 保留兼容 |
| 保留策略 | **按容量**而非按天：`recordingsLimitBytes` 默认 **10 GB**（timelapse 另有 10 GB）。每小时一次：先清孤儿文件，再测 `recordings/` 分配大小，超限则按最早捕获时间把旧段 `is_deleted = 1`（每轮最多 20 段 × 200 轮），活动段永不删除；文件由后续「straggler cleanup」物理删除。`llm_calls` 中超过 64 KB 的请求/响应体被截断。observations/timeline_cards 不会被清理（未验证是否有其他路径）。 |
| 资源监控 | `ProcessCPUMonitor`：每 30s 用 Mach `task_threads/thread_info` 汇总本进程 CPU；≥150% 视为尖峰，仅上报遥测，**不做节流**。`ScreenCaptureMonitor` 统计 SCK 调用。没有电池 / 热状态感知。 |
| 磁盘增长 | 代码内估算 5–10 MB/小时；10 GB 上限约对应 1,000–2,000 小时录制。 |
| 公布的性能数据 | 未在 README 或代码中找到 CPU / 内存实测数字（未验证）。 |

## 隐私与权限处理

- **权限**：只需 Screen Recording（`CGPreflightScreenCaptureAccess()` 检查）；应用不主动调用 `CGRequestScreenCaptureAccess`（请求逻辑在 onboarding 中，未逐行验证）。权限丢失或「已授予但持续失败」时通过 `showScreenRecordingPermissionNotice` 通知并可一键打开系统设置的 Screen Recording 面板。不需要 Accessibility / Input Monitoring（不读键鼠内容）。Automation（AppleEvents）权限仅用于把终端里的 agent 会话拉到前台。
- **应用排除**（`RecordingPrivacyPreferences.swift`）：用户维护一个按 bundle id **或应用名**匹配的黑名单；首次运行自动把检测到的密码管理器（1Password、Bitwarden、Keychain Access、KeePass*、Trezor 等）加入。实现为 `SCContentFilter(display:excludingApplications:exceptingWindows:)`，即**在系统层把这些应用的窗口从画面中抠掉**；若前台应用本身被屏蔽，则改存一张写有「<应用名> 已被隐私设置隐藏」的占位帧（`RecordingPrivacyPlaceholder`），以保持时间线连续且分段分辨率不变。
- **不支持**：按窗口排除、无痕浏览检测、密码输入框检测、URL 过滤。
- **数据外发**：选云端 Provider 时，批次视频（Gemini）或抽样截图（Dayflow 后端 / Gemma）会上传；本地 Provider 时不出机。README 明示这一点。遥测（PostHog、Sentry）可在设置中关闭；`llm_calls` 表会保存完整提示词与响应（截断到 64 KB），含截图里的内容描述，这是一个**本地明文的敏感数据集中点**。
- **沙盒**：`com.apple.security.app-sandbox = false`，开启网络 client/server、音频输入、Downloads 读写。
- **Agent 写入通道**：`agent.sock` 为 `0600` 的 Unix socket，仅在用户打开「Allow edits」时监听，每次写入追加审计日志；读取由 CLI/MCP 直接打开 SQLite。

## 已实现 / 实验性 / 仅规划

| 状态 | 内容 |
|---|---|
| 已实现（稳定） | SCK 截图采集、HEVC 分段存储、容量清理、15 分钟批处理、空闲短路、Gemini / 本地 Ollama·LM Studio / OpenAI 兼容 / Claude Code / Codex / Dayflow 后端 六类 Provider、主备切换、活动卡片时间线、分心标注、每日站会、周回顾、Markdown 导出、时间线聊天、Sparkle 自动更新、菜单栏 + 主窗口、Launch at Login（2026-10-18 新加） |
| 新近 / 变动频繁 | "Flow" 专注会话与分心 Agent（2026-10 几乎所有提交）、`dayflow` CLI + MCP server、Claude Code 插件（`plugins/dayflow/`，含 skills 与 `.mcp.json`）、Dayflow 云后端（需登录；是否付费未验证） |
| 实验性 / 未完全验证 | one-step 时间线生成；Gemma 云端备援；`ScreenCaptureMonitor` 的 SCK 失败遥测（为排查 issue #381） |
| 仅规划 | README 无 roadmap；Releases 无发布说明。音频、键鼠语义、Windows 支持均未见计划（未验证）。 |
| 测试 | 仅 2 个单元测试文件（`ChatCLIProcessRunnerTests`、`DailyRecapGeneratorTests`），无采集/集成测试。 |

## 对 Amai 的借鉴点

1. **`SCScreenshotManager` 截图模式可行且低侵入**：ScreenCaptureKit 的一次性截图在 macOS 14+ 上稳定，并且**不会触发系统的屏幕录制指示器**；配合 `SCContentFilter(excludingApplications:)` 可在系统层面排除敏感应用。这是 Amai 视觉感知的一个经过验证的起点（Screenpipe 走的是持续 `SCStream`，两者可对比）。
2. **帧 → HEVC 分段而非图片目录**：1 fps 假定 + `encodeQuality 0.55` + 600 帧一段，把 1080p 截图压到约 10 MB/小时，同时仍能随机读取单帧。Amai 若需保留原始缓存，可采用类似「视频段 + 行级索引 + 软删除 + 容量上限」方案。
3. **把「空闲秒数」作为每帧元数据，而不是在感知层做决策**：感知层只记录 `secondsSinceLastEventType`，空闲判定留给抽取层（`IdleBatchClassifier` 的阈值体系），符合 Amai「感知层不理解」的边界。
4. **固定时长批处理 + 两步抽取（观察 → 卡片）+ 可改写的最近卡片**：15 分钟批 / 2 分钟间隙切分 / <5 分钟跳过 / 观察带时间戳 / 卡片 10–60 分钟 / 允许模型合并上一张卡，这一套参数是多次迭代后的经验值，可直接作为 Amai 抽取层「短期上下文窗口」设计的参考。`observations` 与 `cards` 的分离正对应 Amai 要求的「观察事实 vs 推断」区分。
5. **Provider 层的抽象形态**：云端大模型（视频输入）、本地小 VLM（逐帧描述再文本合并）、CLI 代理（联系表 + OCR 提示）三种输入形态在同一协议下并存，说明「输入形态随 Provider 变化」应当封装在 Provider 内部，而不是在上游固定。
6. **失败处理的工程细节**：退避序列、10 分钟放弃阈值、权限「已授予但失败」的专门路径、启动时校验最后一段、`llm_calls` 全量日志、每批自动重试 3 次 + 成功后追赶——这些都是长期后台运行必需的，可以直接列入 Amai 的 Recovery Tests 清单。
7. **菜单栏 + 可隐藏主窗口 + 拦截 Cmd-Q（软退出转 accessory 模式）** 的应用形态，是 macOS 常驻感知应用的成熟做法。

## 与 Amai 的差异及不采用的部分

- **单模态、单显示器**：Dayflow 不采集音频和键鼠内容，只录一个显示器。Amai MVP 需要三种模态且应考虑多显示器。
- **没有 OCR / 可访问性文本层**：Dayflow 把像素直接交给 VLM，成本与延迟都高，并且每 15 分钟才能得到结果。Amai 的抽取层应该先有廉价的本地文本抽取（OCR / AX），VLM 只在需要时调用。
- **无长期记忆**：产物是时间线卡片，没有 Markdown 记忆、没有跨天整合、没有用户档案。Amai 的记忆层需另行设计（参考 OpenClaw / Hermes）。
- **云端优先的默认体验**：默认推荐 Gemini（视频上传），本地仅是备选。Amai 应以本地为默认，外发必须显式授权。
- **隐私粒度不够**：无按窗口排除、无密码框 / 无痕窗口识别；`llm_calls` 明文保存所有提示词。Amai 需要更细的高风险信息保护。
- **不做资源自适应**：固定 10 秒间隔，不感知电池 / 热状态 / 画面是否变化，CPU 监控只上报不动作。Amai 需要事件驱动或自适应采样。
- **测试几乎缺失**，不宜把 Dayflow 的实现当作正确性参考，只能参考其设计参数。
- **GRDB 跟踪 master 分支、未锁版本**，工程上不应照搬。

## 许可证与使用注意

- MIT。可以自由阅读、借鉴、修改、商用，只需保留版权声明。
- 没有 CLA、没有双许可。
- 若直接复用其 Swift 代码片段，需在 Amai 中保留 MIT 版权声明；本文档建议只借鉴设计与参数，不复制代码。
- 注意：仓库依赖 Sparkle（MIT）、GRDB（MIT）、Sentry / PostHog SDK（MIT），均无传染性。

## 来源

- https://github.com/JerryZLiu/Dayflow （README、目录结构）
- https://api.github.com/repos/JerryZLiu/Dayflow （stars、语言、license、pushed_at）
- https://api.github.com/repos/JerryZLiu/Dayflow/commits 、/releases
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/LICENSE
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Info.plist
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Dayflow.entitlements
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/App/AppDelegate.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/App/InactivityMonitor.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/System/StatusBarController.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/System/ProcessCPUMonitor.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/System/ScreenRecordingPermissionNotice.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/ScreenRecorder.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/ScreenCaptureMonitor.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/FrameStore.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/RecordingPreferences.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/RecordingPrivacyPreferences.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/RecordingPrivacyPlaceholder.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Recording/StorageManager.swift 、StorageManager+Maintenance.swift 、StorageManager+Screenshots.swift 、StoragePreferences.swift 、VideoProcessingService.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/Analysis/AnalysisManager.swift 、IdleBatchClassifier.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/AI/LLMService.swift 、LLMTypes.swift 、LocalModelPreset.swift 、GeminiModelPreference.swift 、GeminiDirectProvider.swift 、GeminiDirectProvider+Transcription.swift 、GeminiDirectProvider+ActivityCards.swift 、OllamaProvider.swift 、OllamaProvider+Transcription.swift 、ClaudeProvider+Transcription.swift 、GemmaBackupProvider.swift 、DayflowBackendProvider.swift 、OneStepTimelineSupport.swift
- https://raw.githubusercontent.com/JerryZLiu/Dayflow/main/Dayflow/Dayflow/Core/AgentAccess/AgentBridgeServer.swift
- GitHub code search（`gh search code`）：`BatchingConfig` / `targetDuration:` 于 `Core/AI/LLMTypes.swift`
