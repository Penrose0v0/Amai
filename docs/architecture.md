# Amai 系统架构

> 状态：草案（2026-10-19）。描述整体架构、模块职责、数据契约与进程模型。技术栈选型见 [decisions/0002-tech-stack.md](decisions/0002-tech-stack.md)（提案中，待确认）。本文档尽量保持与具体语言无关，待技术栈确认后补充实现层细节。

## 1. 总览

```text
┌──────────────────────────────────────────────────────────────┐
│                         App Shell（菜单栏应用）                 │
│   状态显示 · 启停控制 · 权限引导 · 设置 · 检查器（最小）          │
└───────────────┬──────────────────────────────┬───────────────┘
                │ 控制                          │ 读取
┌───────────────▼───────────┐  ┌───────────────▼───────────────┐
│       Perception 感知层    │  │          Memory 记忆层          │
│  ScreenCapture            │  │  MemoryStore（Markdown）        │
│  AudioCapture             │  │  MemoryWriter（写入规则）        │
│  InteractionCapture       │  │  MemoryIndex（派生索引）         │
│  → PerceptionEvent        │  │  Consolidator（整理/摘要）       │
│  → RawSpool（短期缓冲）    │  │  Retrieval（检索接口）           │
└───────────────┬───────────┘  └───────────────▲───────────────┘
                │ PerceptionEvent               │ ActivitySegment / Observation
┌───────────────▼──────────────────────────────┴───────────────┐
│                      Extraction 抽取层                        │
│  OCR · ASR · 窗口上下文解析 · 时间窗口聚合 · 活动识别            │
│  ModelProvider（本地 / 外部，可替换）                           │
│  → Observation · ActivitySegment                              │
└──────────────────────────────────────────────────────────────┘
                 横切：Config · PrivacyPolicy · Storage · Logging · Clock
```

数据单向流动：**感知 → 抽取 → 记忆**。上层不反向调用下层内部实现；App Shell 通过各层的公开接口控制与读取。

## 2. 模块职责

### 2.1 Perception（感知层）

| 模块 | 输入 | 输出 | 职责 |
|---|---|---|---|
| ScreenCapture | 系统屏幕 | `PerceptionEvent(kind: .screenFrame)` | **定时截图**（Dayflow 风格）：ScreenCaptureKit 单帧截图，固定间隔（默认 10 秒，可配置，按电源档位拉长）；鼠标所在显示器优先；每帧附前台应用元数据、"距上次输入秒数"与 dHash；画面与上一帧相同时标记 `duplicateOf` 供抽取层跳过，但帧仍然编码 |
| FrameStore | 截图帧 | HEVC/MP4 分段 + 帧号 | 所有帧按顺序追加进视频分段（第 N 帧在第 N 秒），每段 600 帧或 600 秒或尺寸变化时轮换；写入中为 `.part`，完成后改名 `.mp4`；相邻相似帧由编码器压缩，磁盘增长约为逐帧 JPEG 的 1/3（Dayflow 实测约 10 MB / 小时） |
| AudioCapture | 系统音频、麦克风 | `PerceptionEvent(kind: .audioChunk)` | 按语音活动切块；静音跳过；来源标记（system / mic）；两者独立开关 |
| InteractionCapture | 键鼠事件、焦点变化 | `PerceptionEvent(kind: .interaction)` | 空闲时长（无需权限）、应用 / 窗口切换；可选的活动强度统计（按键次数、鼠标移动、滚动，需输入监控权限）；**不记录按键内容** |
| PermissionMonitor | 系统权限状态 | 权限状态事件 | 检测屏幕录制、麦克风、辅助功能 / 输入监控权限变化并通知；不信任 preflight 结果，以实际采集成功与否为准 |
| RawSpool | PerceptionEvent | 落盘的原始缓冲 | 按日目录，`events.jsonl` 索引一行一个事件，payload 为视频分段或其他块文件；容量 / 时间双上限；容量清理删最旧的 payload 文件但保留索引行；供抽取层消费 |

设计约束：
- 不做 OCR、不做语义理解。空闲判定也不在感知层做，只记录"距上次输入秒数"供抽取层使用。
- 每个采集器可独立启停，缺少某个权限时其余模态继续工作。
- 采集器必须响应 `PrivacyPolicy` 的"跳过"信号（安全输入、排除应用、用户暂停），并且 **fail-closed**：排除规则无法确认已生效时宁可丢帧。
- 采集参数（截图间隔、图像质量、是否暂停音频）由 `PowerProfile` 统一下发，采集器只订阅。
- 时间戳使用单调时钟 + 墙钟双记录，便于跨模态对齐。

参考依据：Dayflow 验证了 ScreenCaptureKit 单帧截图模式低侵入且不触发系统录屏指示器（[references/dayflow.md](references/dayflow.md)）。Screenpipe 的事件驱动配对捕获 + AX 文本优先方案（[references/screenpipe.md](references/screenpipe.md)）冗余更少但复杂度更高，按 ADR-0002 作为 M6 之后的优化方向，不进入 MVP。

### 2.2 Extraction（抽取层）

| 模块 | 输入 | 输出 | 职责 |
|---|---|---|---|
| Batcher | PerceptionEvent | `ExtractionBatch` | 处理窗口：目标 15 分钟，相邻截图间隔超过 2 分钟即切开，仍在增长的窗口留到下一轮。窗口只是处理单位，不等于一个活动 |
| IdleClassifier / 隐私规则 | 窗口 | 规则片段 | 九成帧键鼠空闲超过 60 秒**且**八成帧画面重复才判为离开（只看键鼠会误判看视频）；全为隐私跳过的窗口记为"隐私跳过"。规则片段不调用模型，相邻同类自动合并 |
| FrameSelector | 窗口内的帧 | 选中帧（默认最多 15） | 首帧、末帧、应用切换帧优先；只丢弃"画面重复、无键鼠输入、同一应用"的帧；超限时均匀采样 |
| ScreenUnderstanding | 选中帧 | 每帧两条 `Observation` | **事实**：感知元数据 + Apple Vision OCR 文本（落盘前凭据脱敏）；**推断**：本地 VLM 的 1–2 句画面描述。都带证据引用（事件 id、视频分段、帧号）。原始帧已过期时只产出元数据事实 |
| ActivitySegmenter | 观察时间线 + 上一个片段 | `ActivitySegment`（可多个） | 纯文本调用模型输出 JSON；校验后裁剪到窗口、消除重叠；第一个片段可声明延续上一个片段，沿用其 id 跨窗口合并 |
| AudioUnderstanding（未实现） | audioChunk 事件 | `Observation` | 本地 ASR；以观察的形式并入同一时间线 |
| ModelProvider | 提示 / 图像 / 音频 | 模型输出 | 抽象接口；MVP 实现为 mlx-swift-lm 嵌入式本地 VLM（Gemma 4）；外部实现可替换；记录数据外发边界。提示词分 cacheable / dynamic 两段以复用 KV cache（Eira 经验） |
| WorkingContext | 近期 ActivitySegment | 短期上下文 | 抽取层的短期工作记忆，有容量上限，不持久化为长期记忆 |

流水线（`ExtractionPipeline`）每 60 秒检查一次就绪窗口，每轮最多处理 4 个：

- **增量**：`extracted/state.json` 的水位线记录已处理到的最后事件，重启后从断点继续。
- **等待**：窗口内有帧所在的视频分段仍在写入时，整窗推迟到下一轮。
- **失败**：同一窗口失败 3 次后按前台应用连续段写入低置信度兜底片段（`fallback:metadata`），流程不卡住；帧描述在重试间缓存，不重复推理。模型未安装不算失败，流水线停在原地等待。
- **节流**：电源档位为 saver / paused 时推迟，插电后追赶；手动"立即处理"忽略档位。
- **存储**：`extracted/YYYY-MM-DD/observations.jsonl` 与 `segments.json`；片段按 id 覆盖更新，`updatedAt` 供记忆层增量读取。

设计约束：
- 任一模态缺失时流水线仍可运行。
- 增量处理：已处理的事件标记进度，重启后从断点继续。
- 每条输出必须带时间范围、来源事件引用、`kind: fact | inference`、置信度、生成它的 provider 标识。
- 不组织跨事件的长期关系，不直接写 Markdown。

### 2.3 Memory（记忆层）

详见 [memory.md](memory.md)。本层对外暴露：

| 接口 | 说明 |
|---|---|
| `ingest(ActivitySegment)` | 接收抽取结果，按写入规则决定写入哪些文件、以何种形式 |
| `retrieve(query, scope, limit)` | 根据问题返回相关记忆片段及来源 |
| `consolidate(trigger)` | 日终 / 周期性整理：daily 汇总、专题更新、summary 刷新 |
| `delete(timeRange | entryId)` | 删除指定时间段或条目的派生记忆 |
| `reindex()` | 从 Markdown 重建派生索引 |

M3 实现（`AmaiMemory`）：`MemoryStore` 写 daily 时间线区块；`MemoryIndex` 负责 trigram 全文索引与 `retrieve`；`MemorySync` 每 60 秒以片段 `updatedAt` 为水位线同步有更新的日期并刷新索引。记忆层通过 `SegmentSource` 协议读取片段，由 App 用抽取层的存储实现，记忆层不依赖抽取层。开发用命令行：`swift run amai-memory search <查询>`。

设计约束：
- Markdown 是唯一真相来源，索引可随时删除重建。
- 用户外部编辑 Markdown 必须被尊重（文件监听 + 重新索引，而非覆盖）。

### 2.4 App Shell

- 菜单栏常驻，显示采集状态（运行 / 暂停 / 权限缺失 / 错误）。
- 启停、暂停、打开记忆目录、设置、最小检查器。
- 首次启动的权限引导与隐私说明。
- 不包含业务逻辑；通过各层公开接口工作。

### 2.5 横切模块

| 模块 | 职责 |
|---|---|
| Config | 采集模态开关、采样参数、排除列表、Provider 配置、存储路径、TTL；本地文件持久化 |
| PrivacyPolicy | 统一判定"当前是否应采集 / 当前数据是否可外发"：安全输入状态、排除应用 / 窗口、无痕窗口、用户暂停、外发开关 |
| PowerProfile | 根据电源（电池 / 插电）、电量、热状态、低电量模式决定采集档位（例如 Performance / Balanced / Saver / Paused），以广播方式下发给采集与抽取；重计算优先在插电时执行 |
| Storage | 目录布局与生命周期（见第 4 节） |
| Logging | 结构化日志；**禁止**记录 OCR 文本、转录文本、窗口标题等内容字段；只记录计数、耗时、错误 |
| Clock | 可注入的时间源，便于测试与回放 |

## 3. 数据契约

以下为概念定义，字段名在实现时保持一致。

```text
PerceptionEvent
  id            唯一标识
  wallTime      墙钟时间（ISO 8601，含时区）
  monoTime      单调时钟（纳秒），用于排序与对齐
  source        screen | audio | interaction | system
  kind          screenFrame | audioChunk | interaction | focusChange | permissionChange ...
  payloadRef    原始数据引用（RawSpool 中的路径或 blob id），可为空
  metadata      { app, bundleId, windowTitle, displayId, durationMs, idleSeconds, ... }
  sensitivity   normal | skipped（被 PrivacyPolicy 跳过时仅保留占位，不含内容）

Observation
  id
  timeRange     [start, end]
  modality      screen | audio | interaction
  kind          fact | inference
  content       文本或结构化内容
  confidence    0–1
  sourceEvents  [PerceptionEvent.id]
  provider      产生该观察的组件 / 模型标识（如 vision-ocr, whisperkit-small, ollama:qwen3）

ActivitySegment
  id
  timeRange
  title         简短活动标题
  summary       自然语言摘要
  category      work | research | communication | reading | entertainment | idle | other（待定稿）
  apps          [bundleId]
  observations  [Observation.id]
  kind          inference（活动识别本质上是推断）
  confidence
  provider

MemoryEntry（写入 Markdown 的最小单元，见 memory.md）
  file, section, content, timestamp, kind(observed | stated | inferred | confirmed), sourceRefs
```

## 4. 存储布局（提案）

```text
~/Library/Application Support/Amai/
├── config.json                 配置
├── raw/                        RawSpool：按日目录，events.jsonl + HEVC 分段 / 音频块；72 小时 TTL + 2 GB 容量上限
├── extracted/                  抽取结果（Observation / ActivitySegment），结构化存储，可清理
├── index/                      记忆派生索引 memory.sqlite（可删除重建）与同步水位线 memory-sync.json
└── logs/                       结构化日志（不含内容字段）

<记忆目录，默认 ~/.amai/memory/，可配置>    Markdown 长期记忆，用户可直接编辑（2026-10-20 用户确认）
```

记忆目录与应用内部数据分离，强调"记忆属于用户"。路径可配置。

## 5. 进程与并发模型（提案）

- MVP 采用**单进程**菜单栏应用：采集、抽取、记忆在同一进程内以独立任务运行。理由：简单、权限只需申请一次、便于调试。
- 抽取与整理任务在后台队列执行，不阻塞采集与 UI。
- 各队列有容量上限；超限时按策略丢弃最旧的低价值数据（如重复帧）并记录计数。
- 模型推理调用必须带超时与取消；失败时事件保留在 spool 中稍后重试，达到重试上限后标记并跳过。
- 后续如需将采集拆为独立 daemon（例如为了崩溃隔离或登录即启动），作为单独的架构决策处理。

## 6. 错误与恢复

| 场景 | 行为 |
|---|---|
| 权限被撤销 | 对应采集器停止，状态显示"权限缺失"，其余模态继续 |
| 显示器 / 音频设备变化 | 采集器重新枚举设备并恢复 |
| 模型不可用（本地服务未启动、外部 API 失败） | 抽取暂停并退避重试，原始数据保留在 TTL 内；状态可见 |
| 进程崩溃 / 重启 | 从 spool 与进度标记恢复，不重复处理 |
| 磁盘空间不足 | 停止采集，提示用户；不删除记忆文件 |
| 用户外部修改记忆文件 | 监听变化并重新索引；整理时以文件内容为准 |

## 7. 模块边界检查清单

实现或评审代码时逐条确认：

- [ ] 感知层没有引入 OCR / 模型 / Markdown 相关依赖。
- [ ] 抽取层没有直接读写记忆目录，也不依赖感知层（只通过 AmaiCore 的 `PerceptionReading` 读取）。
- [ ] 记忆层不依赖任何采集或模型实现。
- [ ] 任何外部网络调用与外部程序调用（`claude -p`）都只发生在 `AmaiCloud`，只用于记忆整理，且仅在用户在设置中确认开启云端来源后发生（ADR-0004 / ADR-0005）；抽取层没有网络调用。
- [ ] 不读取、不保存其他程序的凭据（Claude Code、Codex 等）；ChatGPT 令牌只经官方 SIWC 获得并存钥匙串。
- [ ] 日志中不存在内容字段。
- [ ] 所有队列 / 缓冲有上限。

## 8. 实现层约定（ADR-0002 确认后）

- 单个 Swift Package：`AmaiCore` ← `AmaiPerception` / `AmaiExtraction` / `AmaiMemory` ← `Amai`（App）。三个层 target 互不依赖，只依赖 `AmaiCore`。
- `swift build` 编译；`scripts/bundle.sh` 组装 `.app`（含 MLX metallib、Swift 运行库、签名）；`swift test` 运行不依赖 MLX 权重的测试。
- 日志统一用 `os.Logger`，subsystem `com.amai.app`，category 为模块名；内容字段一律不记录。

## 9. 待确认事项

- 活动片段的时间窗口与分类体系的定稿。
- 音频采集是否进入 MVP 第一阶段，还是在屏幕流水线稳定后加入（roadmap 倾向后者）。

## 10. 后续方向（不在 MVP）

- 连续活动理解：参考无障碍电影自动解说（Audio Description）领域的方法改进时序理解，替代"逐帧描述 + 文本归纳"的两步法。
- 音频观察并入活动时间线；KV cache 复用降低每帧推理成本。
- 事件驱动截图 + 辅助功能文本优先（Screenpipe 路线），用于降低冗余采集与 OCR / VLM 成本。
- 独立采集 daemon（崩溃隔离、登录即启动）。
