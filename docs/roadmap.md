# Amai 开发路线图

> 状态：草案（2026-10-19）。里程碑按"可运行、可验证"的最小增量排列。每个里程碑有明确验收标准；完成或调整时更新本文档。

## 当前阶段

**M1 感知骨架** — 代码已实现（2026-10-19），等待真机验收（见 M1 验收进度）。

## 里程碑

### M0 · 项目启动（文档与选型）

目标：建立文档体系、完成参考研究、确定技术栈。

- [x] AGENTS.md 工程约束
- [x] docs/ 骨架：product、architecture、memory、roadmap、decisions
- [x] references/：Dayflow、Screenpipe、OpenClaw、Hermes、竞品（2026-10-19）
- [x] ADR-0002 技术栈（2026-10-19 用户确认：Swift 6、mlx-swift-lm 嵌入式、GRDB、macOS 15、定时截图）
- [x] 项目骨架：5 个 target、17 个测试通过、`bundle.sh` 产出带 metallib 的 `.app`（2026-10-19）

验收：`docs/` 完整；技术栈 ADR 状态为 Accepted；空项目可构建并通过一个占位测试。**已达成。**

### M1 · 感知骨架（屏幕 + 键鼠 + 控制）

目标：能开着不烦人的采集器。

- 菜单栏应用：运行 / 暂停 / 停止，状态图标，权限引导。
- ScreenCapture：ScreenCaptureKit 单帧定时截图（默认 10 秒），dHash 去重，前台应用 / 窗口元数据，每帧附空闲秒数；睡眠 / 锁屏暂停；失败退避。
- InteractionCapture：空闲时长 + 焦点切换，安全输入检测，无按键内容。
- RawSpool：容量 / TTL 双上限，重启恢复。
- PrivacyPolicy：排除应用 / 窗口列表、暂停、安全输入跳过，fail-closed。
- PowerProfile：电池 / 插电 / 热状态三档节流。
- Logging：无内容字段。

实现进度（2026-10-19）：
- [x] 菜单栏：开始 / 暂停 / 继续 / 停止，四种状态图标，权限申请与系统设置入口，计数显示。
- [x] ScreenCapturer：SCK 单帧定时截图，dHash 标记重复帧，空闲秒数与前台应用元数据，失败退避 60/120/300/600 秒，权限拒绝标记。
- [x] FrameStore（2026-10-20，按用户要求改为 Dayflow 的视频分段方案）：所有帧追加进 HEVC/MP4 分段，600 帧 / 600 秒 / 尺寸变化轮换，`.part` → `.mp4`，睡眠 / 锁屏 / 暂停 / 停止时结束分段；按帧号读回。
- [x] InteractionMonitor：焦点切换事件；被排除应用只留占位。
- [x] RawSpool：按日目录 + JSONL 索引，TTL 整日清理，容量按最旧 payload 清理（跳过写入中的 `.part`），重启重新计量。
- [x] PrivacyPolicy：排除 bundle id / 应用名、用户暂停、安全输入；SCK 过滤不完整时拒绝截图（fail-closed）。
- [x] PowerProfile / PowerMonitor：IOKit 电池 + 热状态 + 低电量模式，四档。
- [x] SystemStateMonitor：睡眠 / 锁屏 / 屏保暂停，恢复延迟 5 秒。
- [x] 单元测试 41 个：spool 限额与恢复、哈希、电源规则、tick 的捕获 / 去重 / 跳过 / 阻断 / 退避路径、焦点事件排除。
- [ ] 窗口标题元数据（SCK 截图路径未取窗口标题，M2 视需要补）。
- [ ] 活动强度统计（CGEventTap，需输入监控权限）。

验收：
- [ ] 连续运行 8 小时无崩溃；CPU / 内存在 product.md 目标范围内（记录测量数据）。
- [ ] 权限撤销 / 恢复、显示器插拔后自动恢复（Recovery Test）。
- [x] spool 不超过上限，过期数据被删除（单元测试）。
- [x] 密码框输入期间无采集记录（单元测试：安全输入 → 占位事件，不调用截图）。
- [x] 启动冒烟：应用启动、生成默认配置与目录、干净退出。
- [x] 真机截图验收（2026-10-20 凌晨，作者机器 M5 Pro）：权限授权后正常落盘；索引与文件一致（38 个截图事件 = 22 重复占位 + 16 个 JPEG）；焦点切换事件正常。
- [x] 视频分段真机验收（2026-10-20 中午）：帧按序写入 `.mp4.part`，重复帧标记正确；授权对话框输入密码期间出现 `secureInput` 占位，证明安全输入检测在真机生效。
- [x] 稳定签名：`scripts/setup-dev-cert.sh` 创建 `Amai Local Dev` 证书后，屏幕录制授权跨重新打包保留（此前 ad-hoc 签名导致每次打包后权限失效，表现为"已授权但仍缺权限"）。
- [x] 菜单栏简化为开始 / 暂停 / 继续；退出时先收尾分段。

首次实测（运行约 9 分钟，10 秒间隔，1080p，JPEG 0.75，接电 performance 档）：

| 指标 | 实测 |
|---|---|
| CPU | 0.1%（采样时） |
| 常驻内存 RSS | 约 105 MB |
| dHash 去重率 | 约 58% 的 tick 判定为同屏，不落盘 |
| 单帧 JPEG | 160–300 KB |
| 磁盘增长 | 约 30 MB / 小时（推算），72 小时 TTL 对应约 2.1 GB，与默认 2 GB 容量上限相当 |

HEVC 分段实测（2026-10-20 中午，同参数，质量 0.55，1662×1080）：

| 指标 | 实测 |
|---|---|
| 第一个分段 | 59 帧 / 10 分钟，1.75 MB |
| 磁盘增长 | 约 10.5 MB / 小时（与 Dayflow 的 10.3 MB / 小时一致），72 小时约 760 MB，远低于 2 GB 容量上限 |
| 索引一致性 | events.jsonl 中引用该分段的帧数 = 容器实际帧数 = 59 |
| 常驻内存 RSS | 约 127 MB |

结论：改为视频分段后磁盘增速约为逐帧 JPEG 的 1/3，TTL 会先于容量上限触发清理；资源占用在 product.md 目标内。

### M2 · 屏幕抽取与活动片段

目标：从截图得到"刚才那 15 分钟在干什么"。

- ScreenUnderstanding：Apple Vision OCR，dHash 相同帧复用，结构化字段（标题、URL）；抽样帧交本地 VLM 描述。
- WindowAggregator + ActivityRecognizer：时间窗口聚合（参考 Dayflow 的 15 分钟批 / 2 分钟间隙切分 / 空闲短路），调用 ModelProvider 生成 ActivitySegment。
- ModelProvider：mlx-swift-lm 嵌入式实现（Gemma 4 e4b 默认），提示词 cacheable / dynamic 分段，内存压力卸载；外部 Provider 接口定义但不实现。
- 增量处理与进度标记。
- 最小检查器：列出 ActivitySegment 及其来源，可删除。

验收：
- 合成数据的 Pipeline Test：固定截图序列 → 稳定的片段输出。
- 本地模型不可用时流水线暂停 / 恢复而不丢数据。
- 作者实际使用 3 天，片段"基本准确"（主观评估记录在 roadmap）。

### M3 · Markdown 记忆写入与检索

目标：daily 自动生成，记忆可检索。

- MemoryStore / MemoryWriter：daily 时间线写入，来源标记，外部编辑保护。
- MemoryIndex：全文索引，增量重建，文件监听。
- Retrieval 接口（开发用 CLI 或内部接口）。
- 删除：按时间段删除派生数据。

验收：
- 从 ActivitySegment 到 daily 文件的 Pipeline Test。
- 用户手动编辑 daily 后，系统不覆盖。
- 删除某时间段后，daily / extracted / raw 中相应数据全部消失。
- `reindex()` 可从零重建索引且检索结果一致。

### M4 · 整理与 summary

目标：记忆开始"沉淀"。

- 日终整理：daily 摘要 / 工作要点；专题候选进入「待澄清」。
- 周期整理：summary.md 差异化更新；快照与回滚。
- 整理策略与 prompt 的设计需在实施前与用户讨论定稿。

验收：
- 两周使用后 summary 能反映主要项目与习惯，作者愿意保留。
- 整理不破坏用户手写内容（测试：注入手写 section 后整理，内容保持）。

### M5 · 音频

目标：会议 / 通话 / 语音内容进入上下文。

- AudioCapture：系统音频 + 麦克风，静音跳过。
- AudioUnderstanding：本地 ASR。
- 与屏幕片段按时间对齐并入 ActivitySegment。

验收：合成音频的转录准确率基线；音频开启后 CPU / 电池增量有测量记录。

### M6 · 稳定性与资源加固

- Performance Tests：长时间运行的 CPU / 内存 / 磁盘曲线。
- Recovery Tests 覆盖 architecture.md 第 6 节全部场景。
- 低功耗模式。

验收：连续运行 7 天的测量报告。

## M6 之后的方向（不承诺）

- 基于记忆的对话问答界面。
- 本地 embedding 语义检索。
- 浏览器域名级排除。
- 主动式 Agent 的最小试验。

## 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-19 | 初版；M0 完成，技术栈按 ADR-0002 确认 |
