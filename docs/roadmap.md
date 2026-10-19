# Amai 开发路线图

> 状态：草案（2026-10-19）。里程碑按"可运行、可验证"的最小增量排列。每个里程碑有明确验收标准；完成或调整时更新本文档。

## 当前阶段

**M0 项目启动** — 已完成（2026-10-19）。下一步：**M1 感知骨架**。

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

验收：
- 连续运行 8 小时无崩溃；CPU / 内存在 product.md 目标范围内（记录测量数据）。
- 权限撤销 / 恢复、显示器插拔后自动恢复（Recovery Test）。
- spool 不超过上限，过期数据被删除。
- 密码框输入期间无采集记录（合成测试）。

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
