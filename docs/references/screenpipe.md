# Screenpipe

> 基本信息（截至 2026-10-19）
>
> | 项目 | 内容 |
> |---|---|
> | 地址 | https://github.com/mediar-ai/screenpipe （官网 https://screenpipe.com ，文档 https://docs.screenpipe.com ）；公司 Negentropy Labs, Inc.（原 Mediar），YC S26 |
> | 许可证 | **Screenpipe Commercial License**（source-available，非 OSI 开源；GitHub API 显示 `NOASSERTION`）。2026-06-10 由 MIT 切换；此前的 MIT 版本仍按 MIT 可用。详见「许可证与使用注意」 |
> | 主要语言 / 技术栈 | Rust（workspace 0.4.52，edition 2021，约 27 个 crate）+ TypeScript（Tauri 2.11 桌面应用，Next.js/React UI，Bun）；macOS 侧经 `sck-rs`（ScreenCaptureKit）、`cidre`（Vision/AX/CoreAudio 绑定）、`objc2`、cpal fork；ONNX Runtime（`ort` 2.0 rc）、whisper.cpp（`whisper-rs` fork）、`mlx-rs`；SQLite（sqlx 0.9 + rusqlite 0.39，FTS5） |
> | 活跃度 | 21,989 stars / 2,250 forks；创建于 2024-06-19；最近推送 2026-10-19；约 14,000 次提交；41 个 open issues；每周多次应用发布（最近 app-v2.7.109，2026-10-14） |
> | 平台 | macOS（Apple Silicon / Intel）、Windows 10/11、Linux x86_64 |

## 项目定位

Screenpipe 自我定义为「Open Computer History」：24/7 本地录制屏幕与音频，把 OCR / 可访问性文本 / 转录 / 输入事件存入本地 SQLite，提供搜索、DVR 式时间线、本地 REST API、MCP server、JS SDK，以及用 Markdown 定义的定时 AI 任务（pipes）。`docs/VISION.md` 把范围收缩为三个动词：**Record、Rewind、Ask**，并明确「稳定优先于功能」、发布版目标 CPU <20%、RAM <3 GB。2026 年起产品重心转向企业（team memory、workflow 挖掘、MDM、SOC 2）。

与 Amai 的关系：Screenpipe 是目前**最完整的跨平台多模态感知 + 本地索引基础设施**，覆盖 Amai 感知层的全部三种模态和抽取层的「廉价文本抽取」部分；但它的「记忆」是可检索的原始历史（SQLite/FTS），不是整理过的长期记忆，且许可证不允许商业使用其代码。

## 架构概览

进程模型：**Tauri 桌面应用（`screenpipe-app`）把引擎 crate 直接链接进自身进程**（`src-tauri/Cargo.toml` 依赖 `screenpipe-engine/-screen/-a11y/-audio/-db`，`tauri.conf.json` 的 `externalBin` 为空；`src-tauri/src` 中由长生命周期的 `ServerCore`（DB、HTTP、pipes、secrets）和短生命周期的 `CaptureSession`（vision、audio、UI recording）组成，旧的 `embedded_server.rs` 已标记为遗留占位）。另有独立的 `screenpipe` CLI 引擎二进制（`crates/screenpipe-engine/src/bin/screenpipe-engine.rs`）用于无 GUI 运行；两者都在 `localhost:3030` 提供同一套 REST API，UI 和外部工具通过它（或直接读 `~/.screenpipe/db.sqlite`）取数据。

| Amai 层 | Screenpipe 对应 | 主要 crate / 文件 |
|---|---|---|
| 感知层 | 事件驱动的「配对捕获」：OS 事件 → 截图 + AX 树 → JPEG + 一行 `frames`；音频流（系统输出 + 麦克风）；UI 事件（点击、输入、剪贴板、切换应用） | `screenpipe-screen`（SCK 截图、帧比较、OCR 引擎）、`screenpipe-a11y`（CGEventTap、AX 树、活动流）、`screenpipe-audio`（设备、VAD、分段）、`screenpipe-capture`（`paired_capture`、`ocr_gate`）、`screenpipe-engine/src/event_driven_capture.rs` |
| 抽取层 | 本机文本抽取：AX 文本优先、OCR 回退（Apple Vision）；Whisper 转录 + 说话人分离；会议检测；语义投影（`screenpipe-semantic`，未深入验证）；LLM 使用集中在 pipes / 聊天 / 会议摘要 | `screenpipe-capture`、`screenpipe-audio/transcription`、`screenpipe-audio/speaker`、`screenpipe-engine/src/meeting_summary`、`semantic_worker.rs` |
| 记忆层 | **不存在整理型记忆**。SQLite + FTS5 是可搜索的原始历史；`memories` / `activity_ledger` / `outputs` / `starred_sessions` 等表是在其上生长的派生物；pipes 可把摘要写到 Obsidian / 本地 Markdown | `screenpipe-db`（migrations）、`screenpipe-engine/src/retention.rs`、`pipes_api.rs` |
| 对外接口 | REST `:3030`（search/frames/audio/elements/health/pipes）、MCP（`screenpipe-mcp`）、`@screenpipe/js` SDK、浏览器扩展、原始 SQL | `packages/` |

## 感知层实现细节

### 屏幕：事件驱动配对捕获（当前实现，`event_driven_capture.rs` + `paired_capture.rs`）

历史：早期是「每监视器一个阻塞循环，0.5 fps 截图 → 帧比较 → OCR → H.265 视频块」（`VISION_PIPELINE_SPEC.md` 描述的 v2.0.440 架构，OCR 阻塞采集、首帧 30–60 秒）。2026-02 起按 `EVENT_DRIVEN_CAPTURE_SPEC.md` 重写为事件驱动、单帧 JPEG；两份 spec 均注明「历史文档，以代码为准」。

| 项目 | 当前实现 |
|---|---|
| 捕获 API | macOS ≥12.3 用 **`sck-rs`（ScreenCaptureKit）持久截图流**；SCK 出现超时/回调错误时回退到 CoreGraphics（xcap），但 `PermissionDenied` 不回退（CG 无法证明权限），且**有窗口排除时拒绝回退**（CG 无法实施排除，fail-closed）。另有独立的 HD 高帧率 SCK 流（`start_hd_capture`，1920px 宽上限）用于会议等场景。 |
| 触发 | 硬触发（应用切换、窗口焦点、手动）绕过防抖；软触发（按键、输入停顿、剪贴板）有 1500 ms 地板；点击、滚动停止、视觉变化、空闲走普通防抖。触发经 4096 容量的 broadcast channel 送达，每 tick 取最高优先级的最后一个，保留全部关联 ID 供 frame linker 把帧和 UI 事件关联。 |
| 默认参数（`EventDrivenCaptureConfig`） | `min_capture_interval_ms = 200`、`idle_capture_interval_ms = 30000`（空闲兜底，也是最大间隔）、`visual_check_interval_ms = 3000`、`visual_change_threshold = 0.05`、`jpeg_quality = 80`、点击/按键/剪贴板触发均默认开。会议中空闲间隔压到 5 s。 |
| 视觉变化检测 | 仅当无其他触发、键盘已空闲 ≥6 s 时每 3 s 采样对比；`FrameComparer`：按 4 倍降采样（1920→480）做颜色哈希早退 + Hellinger 直方图相似度（可选 SSIM，默认关）；注释说明 6 倍降采样「在密集文本页上哈希碰撞」。 |
| 多显示器 | 每个显示器独立循环（各自的触发接收器、AX walker、帧比较器、OCR gate、预算）；只有**承载焦点的显示器**把像素与 AX 树和应用身份配对，其他显示器只做截图 OCR、不写 app/window/URL 元数据；空闲捕获在显示器间错相。冷（无焦点）显示器释放流、5 s 后或焦点回来再恢复。 |
| 去重 | 按设备的 content hash / simhash（来自 AX 树）；连续相同哈希复用上一帧的 elements；HD 会话、会议、空闲捕获绕过去重；30 s 无 DB 写入时强制写一帧以保证时间线连续。 |
| 超时与看门狗 | 单次捕获 20 s（macOS）/15 s；SCK 捕获 12 s、枚举 15 s；流冻结看门狗检测帧序号停止推进后释放流；每个 SCK 路径有串行器和 worker 配额（捕获 2、CG 回退 1），超时任务保留配额直到 OS 调用真正返回。 |
| Retina | 焦点边界用逻辑点，编码/捕获尺寸用 backing 像素；宽度上限作用于像素宽（2026-10-17 刚修过 Retina 尺寸问题）。 |
| 暂停 | 锁屏、电源策略 `capture_paused`、DRM 检测（`drm_detector.rs`）、时间表（`schedule_monitor.rs`）都会释放 OS 捕获流并挂起 AX walker。 |
| 输出 | `SnapshotWriter`：JPEG，路径 `~/.screenpipe/data/YYYY-MM-DD/{ms}_m{monitor}.jpg`，`max_width` 可限制（0 = 原生），编码在 `BackgroundWorkDip` 中让位给前台应用。每次捕获写**一行** `frames`（含 snapshot path、AX 文本、OCR 文本、`text_source`、`capture_trigger`、hash、elements 引用）。 |

### 可访问性与输入事件（`screenpipe-a11y`，macOS 为「完整支持」）

- **事件**：`CGEventTap`（session 级、listen-only；掩码为鼠标按下/抬起、键盘按下/抬起、滚轮；开启活动流时再加鼠标移动/拖动）。Input Monitoring 被拒时跳过 tap，改为 750 ms 轮询剪贴板。
- **按键**：翻译为字符后聚合进 `TextBuffer`（默认 300 ms 停顿形成一条 Text 事件）；带修饰键的记为 Key 事件；Cmd+C/X/V 触发剪贴板抓取；滚动合并为一个手势。**`capture_keystrokes` 默认关闭**（企业版默认开）。
- **焦点/应用**：系统级 AX 查询焦点应用（名字用 `proc_name(pid)`），`AXObserver` 订阅 5 个通知（应用激活/停用、焦点窗口、焦点元素、标题变化），刻意不订阅 value/selection/layout 变化；`NSWorkspace` 通知只设刷新标志。
- **AX 树遍历**（`tree/macos.rs`，未逐行验证）配合 **自适应预算**（`budget.rs`）：按应用最近 8 次遍历耗时分档——Light（<50 ms：间隔 200 ms、最多 5000 节点、超时 250 ms）、Moderate（2 s / 2000 / 200 ms）、Heavy（5 s / 1000 / 150 ms）、Critical（≥250 ms 或连续 3 次截断：60 s / 500 / 100 ms）；30 s 不遍历则衰减恢复。专门针对 Electron 应用的 AX 阻塞主线程问题。
- **点击归因**：命中测试元素的 AXWindow，上溯最多 12 跳 / 15 ms；点击队列 4–64；元素名/窗口标题截断 200 字符，文本值 500/1000 字符。
- **密码字段**：`config.is_password_field(role, name)` 匹配后把名字替换为 `[password field]`、丢弃值、省略祖先链；焦点与点击路径都应用。不依赖 `AXSecureTextField`（未在此文件看到）。
- **浏览器 URL**：`platform/macos.rs` 中 `browser_url` 恒为 `None`（URL 来自别处，可能是树遍历或浏览器扩展，未验证）。
- 持久化（`ui_recorder.rs`）：`ui_events` 表，批量 100 条 / 1 s；DB 停滞时保留最多 max(200, 2×batch) 条，连续失败 >5 次后丢弃 30 s 以上的旧批；`record_input_events` 总开关 + 键盘/剪贴板/点击分项开关（默认均开）。

### 音频（`screenpipe-audio`）

- **系统音频**：macOS 上默认用 **ScreenCaptureKit 音频**（代码注释「SCK-based (Output) audio devices」）；另有实验性 **CoreAudio 系统音频**路径（`experimental_coreaudio_system_audio`，README 称 macOS 14.4+，需要「仅系统音频录制」权限），支持按 pid 建 tap（`start_device_with_tap_pids`）用于会议应用，以及 `~/.screenpipe/audio-exclusions.json` 按 bundle id 排除应用（500 ms 热重载）。具体 CoreAudio API 名称未从源码验证。
- **麦克风**：`cpal` 的 screenpipe fork（含 macOS **VoiceProcessingIO/AEC** 补丁），VPIO 可选，连续失败后回退到普通 HAL 输入。
- **VAD**：`vad-rs` fork（Silero v5/v6）、`webrtc-vad`；分段约 30 s；会议检测（`meeting_detector.rs`）决定何时附着。
- **转录**：`whisper-rs` fork（whisper.cpp，macOS 走 Metal），模型来自 `ggerganov/whisper.cpp`：large-v3-turbo（README 默认）、tiny、tiny-q8、large-v3、large-v3-q5、large-v3-turbo-q8；DTW 关闭。可选 feature：`parakeet` / `qwen3-asr` / `parakeet-mlx`（经 `audiopipe` + `mlx-rs`）、Deepgram 云端、OpenAI 兼容端点。
- **说话人分离**：pyannote `segmentation-3.0.onnx` + WeSpeaker `wespeaker_en_voxceleb_CAM++.onnx`，经 `ort` 运行，模型从仓库 `crates/screenpipe-audio/models/pyannote/` 下载到缓存目录。
- 原则（crate 文档）：设备回调内绝不阻塞/分配；设备健康按设备单独判断，静音不等于失败；仅会议模式下在会议之间释放设备。
- 音频文件以 `.mp4` 落盘后再转录，转录写入 `audio_transcriptions`。

### 电源与资源自适应（`screenpipe-engine/src/power/`）

三档 profile 通过 `tokio::sync::watch` 广播给视觉和音频子系统：

| 参数 | Performance | Balanced | Saver | AudioPaused | FullPause |
|---|---|---|---|---|---|
| 最小捕获间隔 ms | 200 | 500 | 1000 | 1000 | 2000 |
| 空闲间隔 ms | 30,000 | 60,000 | 120,000 | 120,000 | 300,000 |
| 视觉检查间隔 ms / 阈值 | 3000 / 0.05 | 10,000 / 0.10 | 30,000 / 0.15 | 30,000 / 0.15 | 60,000 / 0.20 |
| JPEG 质量 | 80 | 60 | 40 | 40 | 40 |
| 音频 / 截图 / 暂停 | 开 / 开 / 否 | 开 / 开 / 否 | 开 / 开 / 否 | 关 / 关 / 否 | 关 / 关 / 是 |

Auto 模式：热状态 Serious/Critical → Saver；接电且未开低电量 → Performance；电池 ≤10% FullPause、11–20% AudioPaused、21–40% Saver、>40% Balanced；系统低电量模式至少 Saver。用户可固定空闲间隔下限，profile 只能降低不能提高 JPEG 质量。

`resource_monitor.rs`：按调用方间隔（约 30 s）采样 CPU / RSS / footprint / swap / load，按进程组（app、子进程、MCP）拆分；每 tick 调 `malloc_zone_pressure_relief` 归还内存；6 小时窗口内线性回归（斜率 >150 MB/h、r² >0.8、增长 >0.5 GB、末值 >1.5 GB）判定内存泄漏并一次性上报 Sentry。治理动作在 `screenpipe-resource` crate（未验证）。另有 `process_priority.rs`、`disk_pressure.rs`（低磁盘时暂停录制并说明原因）、`fd_limit.rs`、`sleep_monitor.rs`。

## 抽取层实现细节

Screenpipe 的「抽取」绝大部分是**确定性的本机文本抽取**，LLM 只在上层按需调用。

### 文本来源选择（`paired_capture.rs`、`ocr_gate.rs`）

- 默认 **AX 文本优先**；`text_source ∈ {accessibility, ocr, hybrid}`。
- 触发 OCR 的条件（`wants_ocr`）：终端类应用（wezterm/alacritty/kitty/hyper/warp）；会议中且焦点应用/URL 匹配会议模式；无 AX 文本；AX 文本「稀薄」——窗口标题或 URL 命中画布类应用（Google Docs、Figma、Miro…）、总文本 <100 字符、内容角色文本占比 <30%。
- **OCR gate**：截图 → 裁到焦点窗口 → 文本区域检测（约 10–20 ms）→ 裁到检测区域并集（pad 20 px，最小 64 px）→ 像素签名（约 1–3 ms）→ 与上次已提交签名相同则跳过 OCR 并复用缓存文本和重映射坐标；OCR 失败或插入失败则不提交签名，下次重试。注释强调「刻意不再加其他启发式」（此前的稳定等待和区域哈希方案都出过漏检）。
- OCR 引擎：macOS **Apple Vision `VNRecognizeTextRequest`**（经 `cidre`，灰度 8-bit 输入、关闭语言校正、默认识别级别、按语言列表传 locale，输出文本 + 逐词框 + 置信度）；Windows `Windows.Media.Ocr`；Linux Tesseract；另有云端 `Unstructured` 和自定义引擎。`OCR_SEMAPHORE = 1`。README 提到的 RF-DETR / MLX（`screenpipe-rfdetr-mlx` crate，被排除在 workspace 外）用途未验证。
- PII：`use_pii_removal` 开启时在写入前处理（`screenpipe-redact` crate，含 ONNX 本地检测器和远程检测器；`pii-release-gate.md` 描述了「未完成脱敏的内容不释放给受保护 API」的收据机制，但原始 SQL / 帧流等接口不受此门控）。`privacy_filter.rs` 则是搜索时的远程 enclave（Tinfoil，`openai/privacy-filter` 模型）过滤，fail-closed，与本地 PII 模型是两套东西。

### LLM 使用

- **Pipes**：`~/.screenpipe/pipes/*/pipe.md`，frontmatter 声明调度、允许/拒绝的应用和窗口、内容类型（ocr/audio/input/accessibility）、时间范围、是否允许 raw SQL / frames；执行时调用外部编码 agent（pi、claude-code 等）。README 称三层强制（skill gating、agent 拦截、带 per-pipe token 的服务器中间件，`pipe_permissions_middleware.rs`）。内置 pipes：meeting-summary、day-recap、standup-update、time-breakdown、ai-prompt-journal（写 Obsidian/Markdown）、video-export。
- 会议摘要（`meeting_summary/`）、本地聊天（`local_chat.rs`）、工作流分类（`workflow_classifier.rs`）、语义投影（`semantic_worker.rs`、`screenpipe-semantic`，建 `semantic_context` / `semantic_actors` 表）——这些是 2026 年 6–8 月新增，细节未验证。
- 托管模型经 `screenpipe-gateway` / `packages/ai-gateway`；Release notes 提到 "GPT-6 Luna" 为托管默认、新增 Gemini 预设。

## 存储与资源管理

| 项目 | 实现 |
|---|---|
| 位置 | `~/.screenpipe/`：`db.sqlite`、`data/YYYY-MM-DD/*.jpg`（截图）、音频 `.mp4`、`pipes/`、`audio-exclusions.json`、`health-startup.json` |
| 数据库 | SQLite，sqlx + rusqlite（bundled），FTS5；迁移文件按日期编号（2026-05 至 2026-10 共 39 个，含 `unify_ocr_text_into_frames`、`frames_*_redacted_at`、`meeting_transcript_segments`、`audio_diarization_tables`、`semantic_context`、`activity_ledger`、`starred_sessions` 等）；独立的 `screenpipe-sqlite-coordinator` / `-recovery` crate 和 `write_queue.rs`、`failpoint_vfs.rs` 处理并发写与损坏恢复（`SQLITE_RECOVERY.md`） |
| 原始数据 | 截图 JPEG（默认质量 80，可按电源降到 40）、音频 mp4、可选 HD 视频（`hd_recorder.rs`、`video.rs`，FFmpeg）；旧版 H.265 视频块仍可读 |
| 保留（`retention.rs`） | **默认关闭**；开启后按天龄（默认 14 天，1–36,500），三种模式：Media（只删媒体文件，保留所有行以便搜索）、Lean（再删 AX 元素/树 JSON/ui_events，保留 full_text 和转录）、All（删 frames/transcriptions/ui_events 行及文件）。启动 30 s 后每 5 分钟一轮，按 1 小时块处理、块间停 500 ms，带水位线续跑；注释承认 Lean 实际不会缩小 db 文件（未启用 incremental vacuum）。另有 `snapshot_compaction.rs`、`compaction_encoder.rs`（从设置压缩数据库，release notes 提到）。没有按容量的限额（只有低磁盘暂停）。 |
| 加密 | 可选静态加密（`screenpipe-vault`、`screenpipe-secrets`，Keychain 持钥）和端到端同步（`screenpipe-sync`）。未验证实现细节。 |
| 资源指标 | README：CPU 约 5–20%、RAM 0.5–3 GB（捕获部分，本地模型另计），明确为「规划估算而非基准」。`VISION.md` 目标 <20% CPU、<3 GB。旧 spec 的目标：空闲 <0.5% CPU、活跃 <5%、8 小时约 300 MB（3,000–5,000 帧）——是目标值，非实测。`docs/benchmarks/` 存在但未读取。 |
| 遥测 | PostHog 默认开启（可在 Settings → Privacy 关闭）、Sentry 崩溃上报。 |

## 隐私与权限处理

- **权限**（`permission_monitor.rs`）：Screen Recording（优先直接查 TCC 数据库，因 `CGPreflightScreenCaptureAccess` 可能返回陈旧结果；SCK 返回 `PermissionDenied` 时立即上报；枚举到 0 个显示器视为权限丢失的 ground truth）、Microphone（`AVCaptureDevice.authorizationStatus`）、Accessibility（只能轮询）、Keychain（仅开启加密时）。每 5 s 对账，只在状态变化时经 `screenpipe-events` 总线发 `permission_lost/restored`，每权限 5 s 冷却，唤醒后 10 s 静默。**Input Monitoring 未单独监控**，CGEventTap 创建失败时降级为剪贴板轮询。onboarding 用 `tauri-plugin-permission-flow` 插件（未读）。
- **应用 / 窗口排除**（`capture_exclusions.rs`）：窗口过滤规则 + 无痕标志作用于**所有可见窗口**（不只焦点窗口），以 SCK 窗口 ID 列表交给系统在渲染前抠除；两级：探测层（视觉变化 diff，可用旧缓存）和存储层（**fail-closed**：60 s 内无成功刷新则跳过像素）；窗口列表刷新限 5 s，单飞。
- **无痕窗口**（`incognito/macos.rs`）：基础模式按本地化标题匹配（Chrome/Edge/Brave/Vivaldi/Opera/Firefox/Safari），Arc 用 AX identifier `bigIncognitoBrowserWindow`；「增强」模式对 Chromium 用 `osascript` 查询无痕窗口标题（需 Automation 权限，2 s 缓存、失败退避 30 s），负结果仍回落到标题匹配，宁可误杀不漏录。默认开启排除。
- **密码字段**：见上文，替换为 `[password field]` 并丢弃值与祖先。
- **URL 过滤**：`url_filter.rs` 的允许/阻止列表（未读细节）。
- **DRM 内容**：`drm_detector.rs` 检测后暂停捕获。
- **PII**：本地 ONNX 检测器 + 可选远程；企业上传前的 release gate；搜索时的远程 enclave 过滤。文档明确「不是产品级隐私保证」，原始 SQL / 文件系统访问可绕过。
- **数据外发**：核心无需注册即可运行；云端转录（Deepgram）、托管 AI、同步、团队存储、pipes 调用的 agent 都是单独的数据路径；遥测默认开启。企业版默认开启键盘与剪贴板捕获。

## 已实现 / 实验性 / 仅规划

| 状态 | 内容 |
|---|---|
| 已实现（主线） | SCK 事件驱动配对捕获、CG 回退、多显示器、AX 树 + 预算、CGEventTap 输入事件、Apple Vision OCR + OCR gate、JPEG 快照、SQLite/FTS5、系统音频 + 麦克风、Whisper（Metal）、Silero VAD、pyannote/WeSpeaker 分离、会议检测与摘要、电源 profile、资源/泄漏监控、权限监控、窗口/无痕/密码排除、按天龄的三档保留、REST/MCP/SDK、pipes、Tauri 桌面应用、Windows/Linux 后端 |
| 实验性 / 可选 feature | CoreAudio 系统音频 + 按应用排除（macOS 14.4+，需在设置中开启）；Parakeet / Qwen3-ASR / Parakeet-MLX；RF-DETR MLX（crate 存在，排除在 workspace 外）；静态加密与 E2E 同步；本地 PII 模型 release gate（文档列出大量已知缺口）；HD 高帧率录制；semantic / activity_ledger / workflow 分类（2026 年夏新增，迭代中） |
| 规划（`VISION.md`） | Now：让桌面记忆足够可靠；Next：面向 agent 的开放上下文 API（无提示触发）；Later：24/7 加密持续录制 + AI。企业：workflow 自动化挖掘。旧 spec 中的「传感度预设（Low/Medium/High）」在当前代码中未见，已被电源 profile 取代。 |
| 已弃用 | 固定 fps 轮询 + H.265 视频块 + `WindowOcrCache` 架构（代码路径仍有残留以读取旧数据）；`embedded_server.rs` |
| 测试 | `docs/TESTING.md`、`COVERAGE.md`、`evals/`、e2e（`tauri.e2e.json`、`SCREENPIPE_E2E_SEED` 注入故障）、`cargo bench`（OCR、帧比较、多显示器、Apple 泄漏基准）；PR 要求前后对比证据 |

## 对 Amai 的借鉴点

1. **事件驱动而非固定频率采样**是 Screenpipe 用两年时间从「0.5 fps 轮询 + 视频块」迁移到的结论：以应用切换 / 焦点 / 点击 / 输入停顿 / 剪贴板为触发，200 ms 防抖、30 s 空闲兜底、3 s 视觉变化检查，并把截图与 AX 树**在同一时刻配对写成一行**，解决了「缩略图与文本对不上」的根本问题。Amai 感知层应以此为基线设计，而不是从固定 10 秒截图开始。
2. **AX 文本优先、OCR 回退、OCR 只在像素签名变化时运行**：这是 Amai 抽取层「增量处理、避免重复分析」原则的直接范本。Apple Vision 经 `cidre` 调用已被验证可用；「稀薄 AX」的判据（<100 字符、内容角色 <30%、画布类应用名单、终端名单）可直接复用。
3. **可访问性遍历的自适应预算**（按应用近 8 次耗时分四档，Electron 应用自动降级到 60 s 一次）解决了 AX API 阻塞目标应用主线程的真实问题，是 Amai 若采用 AX 必须一并引入的机制。
4. **电源 / 热状态 profile 作为跨子系统的 watch channel**：一个地方决定间隔、JPEG 质量、VAD 阈值、是否暂停音频/截图，各子系统只订阅。参数表（上文）可作为 Amai 的初始值。
5. **fail-closed 的排除逻辑**：有排除规则但系统层无法保证（CG 回退、窗口列表陈旧）时宁可丢帧，也不写入可能含敏感窗口的像素；无痕检测「宁可误杀」。这与 Amai「Privacy First 是架构约束」一致。
6. **长期运行的工程细节清单**：权限直接查 TCC 而非信任 preflight；唤醒后 10 s 静默；SCK 串行器 + worker 配额防止僵尸任务；流冻结看门狗；30 s 无写入强制写帧；DB 写队列和损坏恢复；内存泄漏回归检测；低磁盘暂停并解释原因。可直接转化为 Amai 的 Recovery / Performance 测试用例。
7. **音频栈选型已被验证**：SCK 系统音频 + cpal(VPIO) 麦克风 + Silero VAD + whisper.cpp(Metal) large-v3-turbo + pyannote/WeSpeaker ONNX，在 Apple Silicon 上可长期运行。CoreAudio process tap 路径仍标实验性，说明 macOS 14.4+ 的新 API 还不够稳。
8. **pipes 的权限 frontmatter**（允许/拒绝应用、内容类型、时间范围、是否允许原始帧）是把「抽取结果给 LLM 看什么」做成声明式、可审计策略的好例子，可用于 Amai 的记忆写入与检索授权设计。
9. **keystroke 内容默认不记录、只记录聚合文本事件与热键**，密码字段在 AX 层即替换，这是 Amai 交互模态的合理默认。

## 与 Amai 的差异及不采用的部分

- **许可证**：Screenpipe Commercial License 禁止在商业/生产环境使用其代码（见下节）。Amai 只能借鉴设计，**不能复制 2026-06-10 之后的代码**；若要引用代码，只能取自此前的 MIT 版本并逐文件核对。
- **规模与复杂度**：27 个 crate、跨三平台、企业功能（team memory、MDM、SSO、SOC 2）、同步、网关——远超 Amai「可运行的最小实现」要求。Amai 不应提前引入 Tauri 多进程、Windows/Linux 抽象、企业策略层。
- **记忆模型不同**：Screenpipe 的「记忆」是全量可搜历史（SQLite/FTS/派生表），没有整理、遗忘、用户档案、Markdown 主存；pipes 写 Obsidian 只是输出。Amai 的记忆层是独立设计目标，不能从 Screenpipe 继承。
- **默认保留全部原始数据且保留策略默认关闭**，与 Amai「不默认永久保存原始数据」冲突。Amai 应默认有界缓存。
- **遥测默认开启、远程 PII 过滤、托管 AI 网关**与 Amai 的本地优先立场不一致；企业版默认开键盘/剪贴板捕获更不适用。
- **Rust + Tauri + Next.js** 的技术栈是为跨平台和 Web UI 复用选的；Amai 当前只做 macOS，Swift 原生（如 Dayflow）或 Rust+Swift 混合都可能更轻。此处不作结论，留待技术选型讨论。
- **文档与代码漂移严重**：两份核心 spec 自注「可能错误，以代码为准」，onboarding 文档不描述权限流程。参考时必须以源码为准。

## 许可证与使用注意

- `LICENSE.md`：**Screenpipe Commercial License**，source-available。免费范围：个人非商业使用；非营利、教育、研究；任意规模组织 **7 天**评估/开发/测试。商业使用（「business or production setting」、营利实体、产生收入）**不论公司规模**都需付费许可；禁止将其作为商业产品分发、托管给第三方、嵌入面向客户的产品、或用来构建竞品。许可方保留对软件「包括你所做的修改和补丁」的所有权。席位：个人许可覆盖本人设备，一家公司最多 4 个个人许可，≥5 人需 Team/Enterprise。
- 历史：2026-06-10 三次提交把核心从 MIT 迁到商业许可（`license: move core from MIT to Screenpipe Commercial License`）；许可文本声明「此前以 MIT 发布的版本仍按 MIT 可用」。官方 press 页面仍写 MIT（过时）。
- 对 Amai 的含义：
  - 阅读源码学习设计 → 属于研究/评估，可以。
  - 复制 2026-06-10 之后的代码进 Amai → 若 Amai 将来有任何商业形态，不可以；即便个人使用，许可方对修改保留所有权，也应避免。
  - 复制 2026-06-10 之前的 MIT 代码 → 可以，需保留 MIT 声明，并逐文件确认该文件在当时已存在且未被后续重写（事件驱动捕获、OCR gate、预算等关键模块都是 2026 年 2 月后大改的，**MIT 版本里不存在当前形态**）。
  - 依赖其 fork 的第三方 crate（`screenpipe/sck-rs`、`screenpipe/cpal`、`screenpipe/vad-rs-1`、`EzraEllette/whisper-rs`）→ 各自许可证需单独核查（未验证）。
- `docs/VISION.md` 仍写「open source by default」，与许可证不一致，以 `LICENSE.md` 为准。

## 来源

- https://github.com/mediar-ai/screenpipe （README、目录）
- https://api.github.com/repos/mediar-ai/screenpipe （stars、语言、license、pushed_at）
- https://api.github.com/repos/mediar-ai/screenpipe/commits 、/releases、`commits?path=LICENSE.md`（许可证变更日期）
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/LICENSE.md
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/Cargo.toml
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/CONTRIBUTING.md
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/docs/VISION.md 、EVENT_DRIVEN_CAPTURE_SPEC.md 、VISION_PIPELINE_SPEC.md 、BATCH_TRANSCRIPTION_SPEC.md 、pii-release-gate.md 、health-diagnostics.md 、ONBOARDING.md 、DESIGN.md 、macos-acquisition-handoff.md
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/crates/screenpipe-capture/src/lib.rs 、paired_capture.rs 、ocr_gate.rs
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/crates/screenpipe-screen/Cargo.toml 、src/core.rs 、src/apple.rs 、src/frame_comparison.rs 、src/snapshot_writer.rs 、src/utils.rs 、src/monitor/macos.rs
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/crates/screenpipe-a11y/Cargo.toml 、src/lib.rs 、src/budget.rs 、src/platform/macos.rs 、src/incognito/macos.rs
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/crates/screenpipe-audio/Cargo.toml 、src/lib.rs 、src/transcription/mod.rs 、src/transcription/whisper/mod.rs 、src/transcription/whisper/model.rs 、src/speaker/models.rs 、src/audio_manager/manager.rs 、src/device/mod.rs
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/crates/screenpipe-engine/src/event_driven_capture.rs 、retention.rs 、capture_exclusions.rs 、privacy_filter.rs 、permission_monitor.rs 、resource_monitor.rs 、ui_recorder.rs 、power/mod.rs 、power/profile.rs
- https://raw.githubusercontent.com/mediar-ai/screenpipe/main/apps/screenpipe-app-tauri/src-tauri/tauri.conf.json 、src-tauri/Cargo.toml（经 `gh api`）、src/embedded_server.rs
- GitHub contents API（经 `gh api`）：`crates/`、`crates/*/src/` 目录、`crates/screenpipe-db/src/migrations/`、`apps/screenpipe-app-tauri/src-tauri/src/`、`packages/`
- https://docs.screenpipe.com/
- WebSearch：screenpipe 许可证变更的第三方报道（usecarly.com、chatgate.ai），仅用于交叉确认，细节以 LICENSE.md 为准
