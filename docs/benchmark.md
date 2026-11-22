# 统一 Quality Benchmark

一条命令跑完感知、记忆生成、记忆检索、AI 问答与端到端五组评测，结果写成统一格式（`result.json` + `report.md`），可以重复运行、在版本之间对比。开发用，不随 App 发布。

代码：`Sources/AmaiBenchmark`（逻辑，有单元测试 `Tests/AmaiBenchmarkTests`）、`amai-bench`（入口）。数据：`eval/benchmark/fixtures/`。

## 原则

- **每个指标都写明 Ground Truth 的来源**。同一个数字，GT 是按构造已知、人工标注、关键词锚点还是模型 Judge，可信程度完全不同：

  | 标注 | 含义 |
  |---|---|
  | 合成·按构造 | 合成数据，答案由构造已知（渲染的文字、脚本化的活动、手写的期望） |
  | 人工标注 | 人工给出的标准答案 |
  | 锚点近似 | 关键词命中即算找到；只能作上界或下界 |
  | 模型 Judge | 标准答案是合成或人工的，但判定由本地模型按固定规则给出，有噪声 |
  | 临时 GT | 代码抽样的种子证据，未经人工确认，只用于诊断 |
  | 缺失 | 没有可信的 GT：**不计算**，报告里单列原因 |
  | 实测 | 耗时、数量，不需要 GT |

- **不把缺失的 GT 当成真实数据**。例如记忆整理的"事实准确率"只能给出锚点下界，真正的准确率需要逐条人工审计，报告里列为缺失；真实记忆的检索只有临时 GT 时标为临时 GT，不作结论。
- **优先复用**：记忆生成复用 `AmaiMemoryEval` 与 `eval/memory` 的 17 个场景；检索与问答把合成语料构造成 `QADataset`，直接走 `QARetrievalRunner`、`QARunner`、`QAJudge`、`QAReport`（与 `amai-memory qa-eval` 完全相同的管线与指标定义）；真实记忆的结果从 `qa-eval` 工作目录导入。
- **被测的是正式代码**：采集用真实的 `ScreenCapturer`、`RawSpool`、`FrameStore`（设备由脚本模拟）；抽取用真实的 `ExtractionPipeline`、Vision OCR 与本地视觉模型；记忆用 `MemoryStore` 与 `Consolidator`；问答用 `AssistantSession`。
- **隐私**：全部是本机模型，不向外部服务发送任何数据。合成数据之外，只读取 `--qa-workdir` 里的汇总计数（不含记忆正文）。临时文件在系统临时目录中，运行结束删除。

## 运行

```sh
swift build --build-system native -c release --product amai-bench --scratch-path .build/bench
cp .build/Amai.app/Contents/MacOS/mlx.metallib .build/bench/release/   # 与当前 mlx-swift 匹配的 metallib（见 docs/release.md）

B=.build/bench/release/amai-bench
$B run --suites offline --label offline                   # 不需要生成模型：感知、时间线检查、检索（有向量模型时用它）
$B run --label v0.2.1 --qa-workdir ~/.amai-qa-eval/<目录>   # 全部五组 + 导入真实记忆问答评测的汇总
$B run --suites qa,e2e --repeat 3 --label v0.2.1-x3       # 重复 3 次：指标取均值，保留每次的值
$B compare eval/benchmark/runs/<基线> eval/benchmark/runs/<新版> --output compare.md
$B report eval/benchmark/runs/<目录>                       # 按 result.json 重新生成 report.md
```

- Swift 6.4 默认的 `swiftbuild` 会尝试编译 mlx 的 `.metal` 源文件，没有 Metal Toolchain 时失败，因此用 `--build-system native`。
- 默认模型：抽取与记忆整理 `gemma-4-e4b-it-4bit`（App 默认），作答用 App 配置的助手本地模型（没有时用默认模型），Judge `Qwen2.5-7B-Instruct-4bit`，向量 `Qwen3-Embedding-0.6B`。可用 `--vision`、`--memory-model`、`--answer-model`、`--judge`、`--embedder` 覆盖；未下载的模型对应部分记为跳过。`--no-models` 只保留向量模型。
- 结果在 `eval/benchmark/runs/<时间>-<label>/`：`result.json`（版本 `amai-bench/1`）、`report.md`、`details/`（逐题记录、失败案例，合成内容，不提交）。每组结束都会写一次，长时间运行中断也保留已完成的部分。
- 退出码：有组失败为 3；`compare` 发现变差为 4。
- 运行时最好暂停日常运行的 Amai 的记录：后台抽取与整理会和评测争用 GPU，抬高延迟、拖慢模型组。

## 各组

### 感知（perception，不需要模型）

| 指标 | 定义 |
|---|---|
| 采集覆盖率 | 应采集的 tick 中实际采到的比例 |
| 屏幕状态覆盖率 | 持续 ≥ 1 个采集间隔的内容版本中，至少被采到一帧的比例；短于间隔的单列（定时截图的固有限制） |
| 隐私泄漏 / 跳过原因 / 锁屏停止 | 锁屏、暂停、安全输入、被排除的应用期间不应采集；跳过的占位记录原因正确 |
| 采集流去重 | 与上一帧内容相同（同一活动、同一内容版本）应标为重复：误合并（内容变了却标为重复，等于丢信息）、误拆分 |
| 成对去重 | 三种画面 × 十种变化（相同、光标、时钟、改一行、改一个数字、追加一行、滚动、全部换掉、切换应用）。分别评价采集器用的画面指纹，以及画面指纹 + OCR 文字 |
| OCR 字符错误率 / 整行识别率 | 8 个渲染样本（中、英、日、代码、数字、小字号、深色）。两条路径：直接 JPEG，与正式路径（写入 H.264 分段、经 `SpoolReader` 解码） |

数据：`activity-day.json`（一小时的脚本化活动，见端到端）、`ocr-samples.json`。合成画面没有图片、阴影与复杂背景，结果偏乐观，应视为上界。

### 记忆生成（memory）

运行 `MemoryEvaluation`（开发 7 个 + held-out 10 个场景），映射为：事实召回 / 遗漏率 / 错误归属（锚点）、错误记忆率（场景列出的不应出现的内容被写入，幻觉率的**下界**）、事实准确率**下界**（写入中命中期望事实的比例）、未匹配期望的写入比例（正确的额外信息与幻觉之和，幻觉率的**上界**）、跨天变化处理、类别路由。

时间线：片段写进 daily 再读回，起止时间、标题、摘要与顺序都应不变（不需要模型）。

缺失的 GT：人工审计的事实准确率（口径见 `eval/memory/audits/`；本次写入的逐条明细在 `details/memory-report.md`）、每条事实应引用的来源日期。

### 记忆检索（retrieval）

合成语料 `synthetic-memory.json`（45 天时间线、24 件只出现一次的事、五个长期记忆文件，改编自 `Tests/AmaiInferenceTests/RetrievalEvalTests.swift`），按正式格式由 `MemoryStore` 写出；题目 `synthetic-qa.json` 共 50 道（事实、改写、跨语言、日期、顺序、多证据、追问、无法回答，另有 8 道与记忆无关的问题只用于噪声）。每道题的必需信息点手写为若干可替代的记录片段。

用 `QARetrievalRunner` 跑 pipeline（`MemoryRecall`，4K 预算）、hybrid、keyword，按 `QARetrievalReport` 的定义报告 Recall@K、Precision@K、nDCG@6、证据覆盖率（所需信息点进入提示词的比例）与完整率、4K 预算内覆盖率、无关问题的噪声、第一名得分的 AUROC、延迟。可读分区与 App 默认一致（general、work、goals、daily）。

### AI 问答（qa）

同一套合成语料与 42 道题（不含只用于检索的题）经 `AssistantSession` 作答，`QAJudge`（`qa-rubric-v1`）评分：正确率、宽松得分、幻觉率（回答中有无依据的关于用户的说法）、正确拒答率、无法回答却作答、错误拒答、证据齐全时的正确率、延迟。另报不依赖 Judge 的严格对照"关键点原文命中率"（锚点）。

### 端到端（e2e）

`activity-day.json`：2026-11-20 上午一小时的合成活动——写代码（中途打开 `.env`，内含一个形似 GitHub token 的标记）、一闪而过的通知、订京都的旅馆、1Password（被排除）、Slack 聊天（消息每分钟增加）、网页输入密码（安全输入）、锁屏、写计划、暂停记录后写日记、离开电脑。流程：

```text
脚本 → 模拟设备 → ScreenCapturer → RawSpool / H.264 分段
     → ExtractionPipeline（Vision OCR + 视觉模型切分）→ ExtractionStore
     → MemoryStore（daily 时间线）+ Consolidator（日终摘要与分区整理）
     → MemoryIndex / MemoryAPI → AssistantSession 作答 → QAJudge
```

报告：采集覆盖与隐私泄漏、时间线准确率（≥ 3 分钟的在场活动与片段 IoU ≥ 0.5）、边界误差、应用归属、类别、离开识别、抽取中的 OCR 错误率、8 道题的问答指标，以及**信息漏斗**：每道题的关键词依次是否出现在被采到的屏幕、OCR、片段、记忆文件、提示词中，最后是否答对——定位信息在哪一步丢失。**口令检查**：密码（只在被排除的应用里）、暂停期间写的日记、密钥标记都不应出现在 OCR、片段、记忆文件、提示词、回答与原始缓冲的元数据中（视频帧本身不检查）。

规模小（每个比例的分母只有个位数到几十），适合发现退化，不适合精确比较。

### 真实记忆（real，导入）

给出 `--qa-workdir` 时，读取 `amai-memory qa-eval` 工作目录里的 `summary.json` 与 `retrieval/summary*.json`，指标 id 以 `real.` 开头，数据来源标为 real。不重新运行：真实记忆的题目由出题模型写成、判定由本地 Judge 给出（标为模型 Judge）；检索在人工 GT 导入之前只有临时 GT。

## 版本间比较

`compare` 按指标 id 对齐两次运行：比例类差 ≥ 2 个百分点、其余单位相对差 ≥ 10% 才判为变好或变差；GT 来源不同或数据集摘要不同的指标标为不可比，不给结论；新版有重复运行且差值小于其标准差的 2 倍时注明"可能是噪声"。合成数据改动后摘要随之变化，旧结果与新结果的相关指标自动变为不可比。

## 已知局限

- 合成数据比真实使用干净：画面没有图片与复杂背景，活动边界清楚，语料没有噪声与矛盾。结论是"在理想条件下能否做到"，不能代替真实数据上的评测。
- 记忆生成的自动评分基于锚点，准确率与幻觉率只有上下界；需要人工审计。
- 问答与端到端依赖 7B Judge，判定有噪声；样本少（42 道、8 道），单次运行的差异可能来自随机性，比较时用 `--repeat`。
- 延迟与耗时在评测机器上测得，受后台负载影响，只作数量级参考。
