# 0002 · macOS MVP 技术栈

- 状态：**Accepted**（2026-10-19 用户确认）
- 日期：2026-10-19

## 背景

AGENTS.md 规定：未经讨论不得擅自确定核心语言、GUI 框架、数据库或推理框架。本 ADR 记录经用户确认的方案、备选方案与取舍。

开发环境（2026-10-19 实测）：macOS 26.5、Xcode 26.5、Swift 6.3.2、Apple M5 Pro / 48 GB；另有 Rust 1.98、Python 3.14、Node 24。

本地推理环境（2026-10-19 实测）：

| 来源 | 已有模型 |
|---|---|
| HuggingFace Hub 缓存（MLX 格式，`~/.cache/huggingface/hub`） | `mlx-community/gemma-4-e4b-it-4bit`（4.9 GB）、`mlx-community/gemma-4-26b-a4b-it-4bit`（15 GB）、`mlx-community/Qwen2.5-7B-Instruct-4bit`（4 GB） |
| Ollama 0.24（运行中） | qwen3.5:9b / 27b、gemma4:e4b / 26b / 31b |
| LM Studio（未启动） | Qwen3.6-35B-A3B-MLX-4bit、Qwen3.8-27B-MLX-4bit |

参考项目的实证（详见 [references/dayflow.md](../references/dayflow.md)、[references/screenpipe.md](../references/screenpipe.md)）：

- Dayflow：Swift + SwiftUI 单进程菜单栏应用，ScreenCaptureKit 单帧截图（`SCScreenshotManager`，每 10 秒，不触发系统录屏指示器），`SCContentFilter(excludingApplications:)` 系统层排除敏感应用，GRDB/SQLite，15 分钟批处理 + 本地 VLM 逐帧描述。MIT。
- Screenpipe：Rust 核心经桥接调用 ScreenCaptureKit、Vision、AX、CoreAudio。其事件驱动采集、电源 profile 等经验可借鉴，但 2026-06-10 起改为商业许可，**不可复制其代码**。

用户自有项目 Eira（`~/Desktop/Coding/Eira`）的实证：

- Swift 6 + SwiftPM，**mlx-swift-lm 嵌入式推理**（用户 fork `Penrose0v0/mlx-swift-lm`，含三处 Gemma 4 视觉修复：pooler kernel 截断、保持宽高比缩放、多图打包），Gemma 4 系列 VLM 直接读截图。
- 提示词严格分为 cacheable / dynamic 两段，跨轮复用 KV cache；截图用 dHash（9×8 灰度，阈值 5/64）判断"同屏不重发"；实测同页同屏追问 TTFT 从 5110 ms 降到 258 ms。
- SwiftPM 不编译 `.metal`，Eira 用 `scripts/build-mlx-metallib.sh` 单独编译 9 个预置 kernel 为 `mlx.metallib` 放到 `Contents/MacOS/`，`scripts/bundle.sh` 组装 `.app`、嵌入 Swift 运行库、inside-out 签名。
- 内存压力处理：`DispatchSource.makeMemoryPressureSource(.critical)` 时卸载模型；`MLX.Memory.cacheLimit = 1 GB` 让 VLM 的图像 prefill 临时缓冲归还系统。
- GRDB `DatabasePool` + `DatabaseMigrator`。

## 决策

| 层面 | 选择 | 理由 |
|---|---|---|
| 核心语言 | **Swift 6**（严格并发） | 感知层全部依赖 Apple 框架；长期后台运行的能耗与内存表现最好；与 Eira 共享经验与代码模式 |
| 项目组织 | **单个 Swift Package**，多 library target + 一个 executable target；`scripts/bundle.sh` 组装 `.app` | `AmaiCore`（契约）、`AmaiPerception`、`AmaiExtraction`、`AmaiMemory`、`Amai`（App）；依赖方向在包层面强制；不引入 Xcode 工程，沿用 Eira 的 SwiftPM 工作流 |
| GUI | SwiftUI 菜单栏应用（`MenuBarExtra`，`LSUIElement`） | MVP UI 极简；原生、低资源 |
| 屏幕采集 | **Dayflow 风格定时截图**：ScreenCaptureKit `SCScreenshotManager`，固定间隔（默认 10 秒，可配置），`SCContentFilter` 做系统层应用排除；每帧附"距上次输入秒数"元数据；dHash 判断画面未变则不落盘 | 用户确认。实现简单、低侵入、不触发录屏指示器；事件驱动采集作为后续优化方向保留在 architecture.md |
| 键鼠采集 | `CGEventSource.secondsSinceLastEventType` 读取空闲时长 + `NSWorkspace` 焦点通知；活动强度统计用 `CGEventTap`（listen-only，仅计数，不记内容） | 空闲时长不需要额外权限；活动强度需输入监控权限，可独立关闭 |
| 音频采集 | ScreenCaptureKit 音频流（系统音频）+ `AVAudioEngine`（麦克风）；M5 阶段实现 | 均为系统 API；麦克风默认关闭 |
| OCR | Apple Vision（`VNRecognizeTextRequest`） | 本地、免费、快、中英文可用；作为 VLM 的廉价前置与补充 |
| ASR | WhisperKit（Swift / CoreML，MIT）首选，whisper.cpp 备选 | M5 阶段决定 |
| LLM / VLM | **mlx-swift-lm 嵌入式**（沿用 Eira 的 fork 与 pin），`ModelProvider` 协议隔离；默认模型 `gemma-4-e4b-it-4bit`（后台常驻友好），可选 `gemma-4-26b-a4b-it-4bit`；外部 Provider（Claude API）作为显式开启的实现，MVP 不实现 | 用户确认。无外部服务依赖、分发体验好、KV cache 可控；本机权重已就绪；VLM 可直接理解截图，减少对 OCR 质量的依赖 |
| 索引 / 缓存 | SQLite，**GRDB.swift**（锁定主版本 7） | 用户确认；嵌入式、零运维；Eira 已验证 |
| 配置 | JSON 文件（`Codable`） | 简单、可手改 |
| 测试 | Swift Testing（单元 / 集成）+ XCTest（性能） | 官方工具链 |
| 最低系统版本 | **macOS 15**（Sequoia） | 兼顾 ScreenCaptureKit / Vision 新 API 与未来分发；本机为 26 |

外部依赖：GRDB.swift、mlx-swift-lm（fork）、mlx-swift、swift-huggingface、swift-transformers；后续 WhisperKit。引入其他依赖需在 ADR 或 PR 说明。

## 备选方案

### A. Ollama / LM Studio 经 HTTP 接入（原提案）

- 优点：零依赖、模型管理省事。
- 缺点：依赖外部常驻服务；KV cache 不可控；分发时要求用户先装 Ollama；thinking 类模型会破坏前缀缓存（Eira 实测）。
- 结论：**不采用**（用户决定）。`ModelProvider` 协议保留 HTTP 实现的可能性，但 MVP 不做。

### B. Rust 核心 + Swift 壳（Screenpipe 路线）

- 缺点：双语言 + FFI 边界；MVP 不需要跨平台。结论：不采用。

### C. Python 流水线 + Swift 采集器

- 缺点：后台 Python 进程的内存与能耗；打包复杂。结论：不采用为主干；实验脚本可用 Python。

### D. 事件驱动截图 + AX 文本优先（Screenpipe 路线）

- 优点：更低的冗余采集、更便宜的文本抽取。
- 缺点：实现复杂度明显更高（触发防抖、AX 遍历预算、与截图配对）。
- 结论：**MVP 不采用**（用户决定），先用定时采集跑通全链路；作为 M6 之后的优化方向记录。

## 取舍与风险

| 风险 | 缓解 |
|---|---|
| SwiftPM 不编译 Metal，`swift run` 直接跑 MLX 会崩 | 沿用 Eira 的 `build-mlx-metallib.sh` + `bundle.sh`；测试中涉及 MLX 的用例需 metallib 并以环境变量门控 |
| 依赖用户 fork 的 mlx-swift-lm 固定 commit | 上游合入后切回 tag；Package.swift 注释记录原因 |
| 常驻 VLM 的内存占用（e4b 约 5 GB，26b 约 18 GB） | 默认 e4b；按需加载、空闲超时卸载、内存压力时卸载；`cacheLimit` 限制缓冲池 |
| 定时截图在画面不变时浪费资源 | dHash 去重不落盘；按电源状态拉长间隔 |
| Swift 6 严格并发 + MLX 类型的 Sendable 约束 | Eira 用 Swift 5 语言模式规避；Amai 先尝试 6，仅在 `AmaiExtraction` 必要时降级 |
| 单一平台锁定 | 符合当前阶段目标；`AmaiCore` 保持无平台依赖 |

## 影响

- 目录：`Package.swift`、`Sources/{AmaiCore,AmaiPerception,AmaiExtraction,AmaiMemory,Amai}/`、`Tests/`、`Resources/Info.plist`、`scripts/`。
- 构建：`swift build` 编译；`./scripts/bundle.sh` 产出 `.build/Amai.app`（含 metallib、签名）；`swift test` 跑不依赖 MLX 的测试。
- architecture.md 的感知层描述按定时采集修订；事件驱动方案移到"后续方向"。
