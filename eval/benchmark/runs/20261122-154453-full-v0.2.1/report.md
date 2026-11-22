# Amai Quality Benchmark · full-v0.2.1

- 运行：`20261122-154453-full-v0.2.1`，2026-11-22T06:44:53Z，用时 486 秒
- 代码：`76f199cb08ba`（**工作区有未提交改动**）
- 机器：Apple M5 Pro · 48 GB · macOS 27.2.1；重复 1 次
- 选项：missingModels=``，model.answer=`mlx-community/gemma-4-26b-a4b-it-4bit`，model.embedder=`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`，model.judge=`mlx-community/Qwen2.5-7B-Instruct-4bit`，model.memory=`mlx-community/gemma-4-e4b-it-4bit`，model.vision=`mlx-community/gemma-4-e4b-it-4bit`，suites=`perception,memory,retrieval,qa,e2e,real`

GT 来源：**合成·按构造**＝答案由构造已知；**锚点近似**＝关键词命中，只是上界或下界；**模型 Judge**＝本地模型按固定规则评分，有噪声；**临时 GT**＝代码抽样，未经人工确认；**缺失**＝没有 Ground Truth，不计算；**实测**＝耗时与数量。数据来源 real 表示本人授权的真实记忆（只导入计数）。

## 总览

| 组 | 状态 | 用时 | 指标数 | 说明 |
|---|---|---|---|---|
| 感知 | ✅ | 25.4 s | 26/26 |  |
| 记忆生成 | ✅ | 172.6 s | 19/21 |  |
| 记忆检索 | ✅ | 4.4 s | 41/41 |  |
| AI 问答 | ✅ | 135.8 s | 11/11 |  |
| 端到端 | ✅ | 147.8 s | 27/27 |  |
| 真实记忆（导入 qa-eval 结果） | ✅ | 0.0 s | 43/44 |  |

## 感知

- 模型：ocr `apple-vision (VNRecognizeTextRequest .accurate)`
- 数据：activity-day（synthetic，`eval/benchmark/fixtures/activity-day.json`，sha256 `b9c23d27e6be`）
- 数据：ocr-samples（synthetic，`eval/benchmark/fixtures/ocr-samples.json`，sha256 `5c06043be9a3`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| 采集覆盖率（应采集的 tick 中实际采到） ↑ | 100.0% | 318/318 |  | 合成·按构造 | synthetic |  |
| 屏幕状态覆盖率（持续 ≥ 1 个间隔的内容版本） ↑ | 100.0% | 18/18 |  | 合成·按构造 | synthetic |  |
| 短暂状态覆盖率（持续 < 1 个间隔）  | 0.0% | 0/1 |  | 合成·按构造 | synthetic | 定时截图的固有限制，仅供参考 |
| 内容出现到首次采到的平均延迟 ↓ | 0.1 s |  |  | 合成·按构造 | synthetic | 采集间隔 10 秒 |
| 隐私泄漏（不应采集却采到的 tick） ↓ | 0.0% | 0/72 |  | 合成·按构造 | synthetic | 锁屏、暂停、安全输入、被排除的应用 |
| 跳过原因正确率 ↑ | 100.0% | 42/42 |  | 合成·按构造 | synthetic |  |
| 锁屏时停止采集 ↑ | 100.0% | 30/30 |  | 合成·按构造 | synthetic |  |
| 单次 tick 耗时中位数（含编码写入） ↓ | 11 ms |  |  | 实测 | synthetic | 评测机器上测得，仅作数量级参考 |
| 采集流·误合并率（内容变了却标为重复） ↓ | 0.0% | 0/14 |  | 合成·按构造 | synthetic | 被标为重复的帧不再送去描述，等于丢信息 |
| 采集流·误拆分率（内容没变却没标为重复） ↓ | 0.3% | 1/300 |  | 合成·按构造 | synthetic | 多做无用的识别与推理 |
| 成对去重准确率·画面指纹（采集器使用） ↑ | 93.1% | 27/29 |  | 合成·按构造 | synthetic |  |
| 误合并率·画面指纹（采集器使用） ↓ | 11.8% | 2/17 |  | 合成·按构造 | synthetic |  |
| 误拆分率·画面指纹（采集器使用） ↓ | 0.0% | 0/12 |  | 合成·按构造 | synthetic |  |
| 成对去重准确率·画面指纹 + OCR 文字 ↑ | 75.9% | 22/29 |  | 合成·按构造 | synthetic |  |
| 误合并率·画面指纹 + OCR 文字 ↓ | 23.5% | 4/17 |  | 合成·按构造 | synthetic |  |
| 误拆分率·画面指纹 + OCR 文字 ↓ | 25.0% | 3/12 |  | 合成·按构造 | synthetic |  |
| OCR 字符错误率·正式路径（视频分段解码） ↓ | 5.5% | 61/1118 |  | 合成·按构造 | synthetic |  |
| OCR 整行识别率·正式路径（视频分段解码） ↑ | 78.3% | 36/46 |  | 合成·按构造 | synthetic | 归一化后整行作为子串出现 |
| OCR 字符错误率·直接 JPEG ↓ | 5.4% | 60/1118 |  | 合成·按构造 | synthetic |  |
| OCR 整行识别率·直接 JPEG ↑ | 82.6% | 38/46 |  | 合成·按构造 | synthetic | 归一化后整行作为子串出现 |
| OCR 字符错误率·code ↓ | 10.3% | 20/195 |  | 合成·按构造 | synthetic |  |
| OCR 字符错误率·en ↓ | 2.3% | 11/472 |  | 合成·按构造 | synthetic |  |
| OCR 字符错误率·ja ↓ | 6.7% | 5/75 |  | 合成·按构造 | synthetic |  |
| OCR 字符错误率·mixed ↓ | 5.8% | 6/104 |  | 合成·按构造 | synthetic |  |
| OCR 字符错误率·zh ↓ | 7.0% | 19/272 |  | 合成·按构造 | synthetic |  |
| OCR 单帧耗时中位数 ↓ | 85 ms |  |  | 实测 | synthetic | 评测机器上测得 |

- 去重判错的样本：text：文档 16px·光标+时钟 应为同一屏；image：文档 16px·改一个数字 应为不同画面；text：文档 16px·改一个数字 应为不同画面；text：英文 12px·改一行 应为不同画面；image：英文 12px·改一个数字 应为不同画面；text：英文 12px·改一个数字 应为不同画面；text：英文 12px·追加一行 应为不同画面；text：代码深色 13px·光标闪烁 应为同一屏；text：代码深色 13px·光标+时钟 应为同一屏
- OCR 错误率最高的样本：code-dark-14 10.3%，zh-chat-dark-16 8.6%，zh-small-12 7.5%
- 合成画面没有图片、阴影与复杂背景，OCR 与去重结果偏乐观，应视为上界。
- 明细：`details/perception-ocr.json`

## 记忆生成

- 模型：memory `mlx-community/gemma-4-e4b-it-4bit`
- 数据：memory-scenarios（synthetic，`eval/memory/scenarios.json`，sha256 `c3a05082d08e`）
- 数据：memory-heldout（synthetic，`eval/memory/heldout.json`，sha256 `0eda7e2fd235`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| 时间线保真度（片段写入 daily 后起止时间、标题、摘要一致） ↑ | 100.0% | 29/29 |  | 合成·按构造 | synthetic |  |
| 时间线顺序正确的天数 ↑ | 100.0% | 22/22 |  | 合成·按构造 | synthetic |  |
| 事实召回率 ↑ | 61.1% | 11/18 |  | 锚点近似 | synthetic | 期望事实的全部锚点出现在同一条有效条目中 |
| 错误记忆率（不应出现的内容命中） ↓ | 13.9% | 5/36 |  | 锚点近似 | synthetic | 只覆盖场景列出的错误类型（第三方数据、阅读当计划、把关注写成诊断等），是幻觉率的下界 |
| 遗漏率 ↓ | 38.9% | 7/18 |  | 锚点近似 | synthetic |  |
| 错误归属率 ↓ | 5.6% | 1/18 |  | 锚点近似 | synthetic |  |
| 事实准确率下界（写入中命中期望事实） ↑ | 64.7% | 11/17 |  | 锚点近似 | synthetic | 未命中期望的写入不一定错，真实准确率 ≥ 此值 |
| 未匹配期望的写入比例  | 35.3% | 6/17 |  | 锚点近似 | synthetic | 正确的额外信息与幻觉的总和，需要人工审计区分；幻觉率 ≤ 此值 |
| 跨天变化处理正确率 ↑ | 66.7% | 2/3 |  | 锚点近似 | synthetic | 旧信息撤下、新信息有效 |
| 新旧信息同时有效 ↓ | 0 |  |  | 锚点近似 | synthetic |  |
| 类别路由召回率 ↑ | 96.2% | 25/26 |  | 合成·按构造 | synthetic |  |
| 多余路由 ↓ | 8 |  |  | 合成·按构造 | synthetic |  |
| 结构化输出不合格率 ↓ | 0.0% | 0/55 |  | 合成·按构造 | synthetic |  |
| 写入条目数  | 17 |  |  | 实测 | synthetic |  |
| 模型调用次数  | 55 |  |  | 实测 | synthetic |  |
| 事实召回率·dev ↑ | 70.0% | 7/10 |  | 锚点近似 | synthetic | 期望事实的全部锚点出现在同一条有效条目中 |
| 错误记忆率（不应出现的内容命中）·dev ↓ | 0.0% | 0/10 |  | 锚点近似 | synthetic | 只覆盖场景列出的错误类型（第三方数据、阅读当计划、把关注写成诊断等），是幻觉率的下界 |
| 事实召回率·heldout ↑ | 50.0% | 4/8 |  | 锚点近似 | synthetic | 期望事实的全部锚点出现在同一条有效条目中 |
| 错误记忆率（不应出现的内容命中）·heldout ↓ | 19.2% | 5/26 |  | 锚点近似 | synthetic | 只覆盖场景列出的错误类型（第三方数据、阅读当计划、把关注写成诊断等），是幻觉率的下界 |
| 事实准确率（人工审计） ↑ | — |  |  | 缺失 | synthetic | 需要对本次写入逐条人工审计（明细 details/memory-report.md，口径见 eval/memory/audits/）；自动评分不能区分正确的额外信息与幻觉 |
| 写入条目的来源日期准确率 ↑ | — |  |  | 缺失 | synthetic | 场景只标了事实锚点，没有标注每条事实应引用的日期 |

- 参考：2026-11-03 的人工审计（eval/memory/audits/2026-11-03.md，较早的代码版本）中 Gemma 4 E4B 的人工 Precision 为 47%、Recall 39%；不是本次运行的结果，不能直接比较。
- 明细：`details/memory-report.md`，`details/memory-results.json`

## 记忆检索

- 模型：embedder `mlx:Qwen3-Embedding-0.6B-4bit-DWQ`
- 数据：synthetic-memory（synthetic，`eval/benchmark/fixtures/synthetic-memory.json`，sha256 `0447ec1741d3`）
- 数据：synthetic-qa（synthetic，`eval/benchmark/fixtures/synthetic-qa.json`，sha256 `3a58e227efb3`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| Recall@1·助手管线（4K 预算） ↑ | 81.9% |  |  | 合成·按构造 | synthetic |  |
| Recall@3·助手管线（4K 预算） ↑ | 94.4% |  |  | 合成·按构造 | synthetic |  |
| Recall@6·助手管线（4K 预算） ↑ | 94.4% |  |  | 合成·按构造 | synthetic |  |
| Recall@10·助手管线（4K 预算） ↑ | 97.2% |  |  | 合成·按构造 | synthetic |  |
| Precision@1·助手管线（4K 预算） ↑ | 86.1% |  |  | 合成·按构造 | synthetic |  |
| Precision@3·助手管线（4K 预算） ↑ | 37.0% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·助手管线（4K 预算） ↑ | 18.5% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·助手管线（4K 预算） ↑ | 0.908 |  |  | 合成·按构造 | synthetic |  |
| 证据覆盖率（所需信息点进入提示词的比例） ↑ | 100.0% |  |  | 合成·按构造 | synthetic |  |
| 证据完整率（所需信息点全部进入提示词） ↑ | 100.0% |  |  | 合成·按构造 | synthetic |  |
| 提示词中记忆的平均 token  | 92.2 |  |  | 实测 | synthetic |  |
| Recall@1·混合检索 ↑ | 83.3% |  |  | 合成·按构造 | synthetic |  |
| Recall@3·混合检索 ↑ | 95.8% |  |  | 合成·按构造 | synthetic |  |
| Recall@6·混合检索 ↑ | 97.2% |  |  | 合成·按构造 | synthetic |  |
| Recall@10·混合检索 ↑ | 100.0% |  |  | 合成·按构造 | synthetic |  |
| Precision@1·混合检索 ↑ | 86.1% |  |  | 合成·按构造 | synthetic |  |
| Precision@3·混合检索 ↑ | 35.2% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·混合检索 ↑ | 19.0% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·混合检索 ↑ | 0.932 |  |  | 合成·按构造 | synthetic |  |
| 4K 预算内的证据覆盖率·混合检索 ↑ | 100.0% |  |  | 合成·按构造 | synthetic |  |
| Recall@1·纯关键词 ↑ | 22.2% |  |  | 合成·按构造 | synthetic |  |
| Recall@3·纯关键词 ↑ | 44.4% |  |  | 合成·按构造 | synthetic |  |
| Recall@6·纯关键词 ↑ | 50.0% |  |  | 合成·按构造 | synthetic |  |
| Recall@10·纯关键词 ↑ | 50.0% |  |  | 合成·按构造 | synthetic |  |
| Precision@1·纯关键词 ↑ | 25.0% |  |  | 合成·按构造 | synthetic |  |
| Precision@3·纯关键词 ↑ | 16.7% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·纯关键词 ↑ | 9.7% |  |  | 合成·按构造 | synthetic | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·纯关键词 ↑ | 0.393 |  |  | 合成·按构造 | synthetic |  |
| 4K 预算内的证据覆盖率·纯关键词 ↑ | 50.0% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·pipeline·absentEntity ↓ | 33.3% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·pipeline·falsePremise  | 100.0% |  |  | 合成·按构造 | synthetic | 错误前提的题，相关记忆有助于反驳，不算噪声 |
| 无关问题仍返回记忆的比例·pipeline·noRecordDate ↓ | 0.0% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·pipeline·offTopic ↓ | 25.0% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·hybrid·absentEntity ↓ | 33.3% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·hybrid·falsePremise  | 100.0% |  |  | 合成·按构造 | synthetic | 错误前提的题，相关记忆有助于反驳，不算噪声 |
| 无关问题仍返回记忆的比例·hybrid·noRecordDate ↓ | 0.0% |  |  | 合成·按构造 | synthetic |  |
| 无关问题仍返回记忆的比例·hybrid·offTopic ↓ | 25.0% |  |  | 合成·按构造 | synthetic |  |
| 第一名得分区分可回答 / 无法回答（AUROC） ↑ | 0.942 |  |  | 合成·按构造 | synthetic |  |
| 检索延迟中位数·pipeline ↓ | 16 ms |  |  | 实测 | synthetic | 评测机器上测得 |
| 检索延迟中位数·hybrid ↓ | 16 ms |  |  | 实测 | synthetic | 评测机器上测得 |
| 检索延迟中位数·keyword ↓ | 2 ms |  |  | 实测 | synthetic | 评测机器上测得 |
- 明细：`details/retrieval-summary.json`，`details/retrieval-report.md`

## AI 问答

- 模型：answer `mlx-community/gemma-4-26b-a4b-it-4bit`，embedder `mlx:Qwen3-Embedding-0.6B-4bit-DWQ`，judge `mlx-community/Qwen2.5-7B-Instruct-4bit`
- 数据：synthetic-memory（synthetic，`eval/benchmark/fixtures/synthetic-memory.json`，sha256 `0447ec1741d3`）
- 数据：synthetic-qa（synthetic，`eval/benchmark/fixtures/synthetic-qa.json`，sha256 `3a58e227efb3`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| 正确率（可回答的题） ↑ | 88.9% | 32/36 |  | 模型 Judge | synthetic |  |
| 宽松得分（correct 1、partial 0.5） ↑ | 94.4% |  |  | 模型 Judge | synthetic |  |
| 幻觉率（回答含无依据的说法） ↓ | 11.9% | 5/42 |  | 模型 Judge | synthetic | Judge 列出的、既不被证据也不被所给记忆支持的关于用户的说法；可能漏报 |
| 正确拒答率（无法回答的题明确说没有记录） ↑ | 83.3% | 5/6 |  | 模型 Judge | synthetic |  |
| 无法回答却作答（编造或接受错误前提） ↓ | 16.7% | 1/6 |  | 模型 Judge | synthetic |  |
| 错误拒答率（可回答却说没有记录） ↓ | 0.0% | 0/36 |  | 模型 Judge | synthetic |  |
| 证据齐全时的正确率（作答能力） ↑ | 88.9% | 32/36 |  | 模型 Judge | synthetic |  |
| 证据召回（进入提示词） ↑ | 100.0% |  |  | 合成·按构造 | synthetic |  |
| 关键点原文命中率（严格，不用 Judge） ↑ | 41.7% | 15/36 |  | 锚点近似 | synthetic | 措辞不同即算未命中，是正确率的保守对照 |
| 首字延迟中位数 ↓ | 200 ms |  |  | 实测 | synthetic | 评测机器上测得 |
| 回答总耗时中位数 ↓ | 726 ms |  |  | 实测 | synthetic | 评测机器上测得 |

- Judge 是 7B 本地模型，判定有噪声；关键点命中率是不依赖 Judge 的严格对照（措辞不同也算未命中）。
- 明细：`details/qa-summary.json`，`details/qa-records.jsonl`，`details/qa-report.md`

## 端到端

- 模型：answer `mlx-community/gemma-4-26b-a4b-it-4bit`，embedder `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`，judge `mlx-community/Qwen2.5-7B-Instruct-4bit`，memory `mlx-community/gemma-4-e4b-it-4bit`，vision `mlx-community/gemma-4-e4b-it-4bit`
- 数据：activity-day（synthetic，`eval/benchmark/fixtures/activity-day.json`，sha256 `b9c23d27e6be`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| 采集覆盖率（应采集的 tick 中实际采到） ↑ | 100.0% | 318/318 |  | 合成·按构造 | synthetic |  |
| 隐私泄漏（不应采集却采到的 tick） ↓ | 0.0% | 0/72 |  | 合成·按构造 | synthetic | 锁屏、暂停、安全输入、被排除的应用 |
| 时间线准确率（活动与片段 IoU ≥ 0.5） ↑ | 100.0% | 4/4 |  | 合成·按构造 | synthetic | 只评价 ≥ 3 分钟、用户在场、应采集的活动 |
| 片段边界平均误差 ↓ | 1.1 分 |  |  | 合成·按构造 | synthetic |  |
| 片段应用归属正确 ↑ | 100.0% | 4/4 |  | 合成·按构造 | synthetic |  |
| 片段类别与期望一致 ↑ | 75.0% | 3/4 |  | 合成·按构造 | synthetic | 类别是人工给出的期望，有主观成分 |
| 离开时段识别为 idle ↑ | 100.0% | 1/1 |  | 合成·按构造 | synthetic |  |
| 抽取中的 OCR 字符错误率 ↓ | 6.2% | 543/8770 |  | 合成·按构造 | synthetic | 含脱敏替换与存储截断的影响 |
| 抽取耗时（一小时活动） ↓ | 88.3 s |  |  | 实测 | synthetic |  |
| 片段数  | 5 |  |  | 实测 | synthetic |  |
| 兜底窗口数（模型失败） ↓ | 0 |  |  | 实测 | synthetic |  |
| 正确率（可回答的题） ↑ | 60.0% | 3/5 |  | 模型 Judge | synthetic |  |
| 宽松得分（correct 1、partial 0.5） ↑ | 60.0% |  |  | 模型 Judge | synthetic |  |
| 幻觉率（回答含无依据的说法） ↓ | 12.5% | 1/8 |  | 模型 Judge | synthetic | Judge 列出的、既不被证据也不被所给记忆支持的关于用户的说法；可能漏报 |
| 正确拒答率（无法回答的题明确说没有记录） ↑ | 100.0% | 3/3 |  | 模型 Judge | synthetic |  |
| 无法回答却作答（编造或接受错误前提） ↓ | 0.0% | 0/3 |  | 模型 Judge | synthetic |  |
| 错误拒答率（可回答却说没有记录） ↓ | 0.0% | 0/5 |  | 模型 Judge | synthetic |  |
| 关键点原文命中率（严格，不用 Judge） ↑ | 0.0% | 0/5 |  | 锚点近似 | synthetic | 措辞不同即算未命中，是正确率的保守对照 |
| 首字延迟中位数 ↓ | 435 ms |  |  | 实测 | synthetic | 评测机器上测得 |
| 回答总耗时中位数 ↓ | 643 ms |  |  | 实测 | synthetic | 评测机器上测得 |
| 信息保留·屏幕被采到 ↑ | 100.0% | 5/5 |  | 合成·按构造 | synthetic |  |
| 信息保留·OCR ↑ | 100.0% | 5/5 |  | 锚点近似 | synthetic |  |
| 信息保留·活动片段 ↑ | 80.0% | 4/5 |  | 锚点近似 | synthetic | 片段由模型改写，关键词不出现不一定是丢了信息 |
| 信息保留·记忆文件 ↑ | 80.0% | 4/5 |  | 锚点近似 | synthetic |  |
| 信息保留·进入提示词 ↑ | 80.0% | 4/5 |  | 锚点近似 | synthetic |  |
| 信息保留·回答正确（Judge） ↑ | 60.0% | 3/5 |  | 模型 Judge | synthetic |  |
| 口令 / 密钥 / 暂停期间内容出现在产物中的次数 ↓ | 0 |  |  | 合成·按构造 | synthetic | 检查 3 个标记 × 6 类产物（视频帧本身不检查） |

- 整理：路由 work,goals；被拒绝的操作 4 条
- 一小时的合成活动，规模小：每个比例的分母只有个位数到几十，适合发现退化，不适合精确比较。
- 明细：`details/e2e-funnel.json`，`details/e2e-segments.md`，`details/e2e-qa-records.jsonl`，`details/e2e-memory.md`

## 真实记忆（导入 qa-eval 结果）

- 模型：answer `mlx:gemma-4-26b-a4b-it-4bit`，embedder `mlx:Qwen3-Embedding-0.6B-4bit-DWQ`，judge `mlx:Qwen2.5-7B-Instruct-4bit`
- 数据：real-qa-dataset（real，`~/.amai-qa-eval/20261119-real`，sha256 `4b76a0d5d8d7`）

| 指标 | 值 | 计数 | 范围 | GT | 数据 | 说明 |
|---|---|---|---|---|---|---|
| 正确率（可回答的题） ↑ | 55.3% | 47/85 |  | 模型 Judge | real |  |
| 宽松得分（correct 1、partial 0.5） ↑ | 65.3% |  |  | 模型 Judge | real |  |
| 幻觉率（回答含无依据的说法） ↓ | 32.0% | 32/100 |  | 模型 Judge | real | Judge 列出的、既不被证据也不被所给记忆支持的关于用户的说法；可能漏报 |
| 正确拒答率（无法回答的题明确说没有记录） ↑ | 93.3% | 14/15 |  | 模型 Judge | real |  |
| 无法回答却作答（编造或接受错误前提） ↓ | 6.7% | 1/15 |  | 模型 Judge | real |  |
| 错误拒答率（可回答却说没有记录） ↓ | 1.2% | 1/85 |  | 模型 Judge | real |  |
| 证据齐全时的正确率（作答能力） ↑ | 79.5% | 35/44 |  | 模型 Judge | real |  |
| 证据召回（进入提示词） ↑ | 59.6% |  |  | 临时 GT | real |  |
| 首字延迟中位数 ↓ | 462 ms |  |  | 实测 | real | 评测机器上测得 |
| 回答总耗时中位数 ↓ | 1180 ms |  |  | 实测 | real | 评测机器上测得 |
| Recall@1·助手管线（4K 预算） ↑ | 25.4% |  |  | 临时 GT | real |  |
| Recall@3·助手管线（4K 预算） ↑ | 34.3% |  |  | 临时 GT | real |  |
| Recall@6·助手管线（4K 预算） ↑ | 46.3% |  |  | 临时 GT | real |  |
| Recall@10·助手管线（4K 预算） ↑ | 60.4% |  |  | 临时 GT | real |  |
| Precision@1·助手管线（4K 预算） ↑ | 28.4% |  |  | 临时 GT | real |  |
| Precision@3·助手管线（4K 预算） ↑ | 13.4% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·助手管线（4K 预算） ↑ | 9.0% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·助手管线（4K 预算） ↑ | 0.368 |  |  | 临时 GT | real |  |
| 证据覆盖率（所需信息点进入提示词的比例） ↑ | 94.0% |  |  | 临时 GT | real |  |
| 证据完整率（所需信息点全部进入提示词） ↑ | 92.5% |  |  | 临时 GT | real |  |
| 提示词中记忆的平均 token  | 2522.1 |  |  | 实测 | real |  |
| Recall@1·混合检索 ↑ | 38.8% |  |  | 临时 GT | real |  |
| Recall@3·混合检索 ↑ | 53.7% |  |  | 临时 GT | real |  |
| Recall@6·混合检索 ↑ | 68.7% |  |  | 临时 GT | real |  |
| Recall@10·混合检索 ↑ | 71.6% |  |  | 临时 GT | real |  |
| Precision@1·混合检索 ↑ | 41.8% |  |  | 临时 GT | real |  |
| Precision@3·混合检索 ↑ | 19.9% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·混合检索 ↑ | 12.7% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·混合检索 ↑ | 0.545 |  |  | 临时 GT | real |  |
| 4K 预算内的证据覆盖率·混合检索 ↑ | 91.0% |  |  | 临时 GT | real |  |
| Recall@1·纯关键词 ↑ | 25.4% |  |  | 临时 GT | real |  |
| Recall@3·纯关键词 ↑ | 33.6% |  |  | 临时 GT | real |  |
| Recall@6·纯关键词 ↑ | 44.0% |  |  | 临时 GT | real |  |
| Recall@10·纯关键词 ↑ | 56.0% |  |  | 临时 GT | real |  |
| Precision@1·纯关键词 ↑ | 28.4% |  |  | 临时 GT | real |  |
| Precision@3·纯关键词 ↑ | 12.9% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| Precision@6·纯关键词 ↑ | 8.7% |  |  | 临时 GT | real | 每题只有 1–2 个信息点，P@K 的上限约为 信息点数/K |
| nDCG@6·纯关键词 ↑ | 0.355 |  |  | 临时 GT | real |  |
| 4K 预算内的证据覆盖率·纯关键词 ↑ | 73.9% |  |  | 临时 GT | real |  |
| 第一名得分区分可回答 / 无法回答（AUROC） ↑ | 0.984 |  |  | 临时 GT | real |  |
| 检索延迟中位数·pipeline ↓ | 64 ms |  |  | 实测 | real | 评测机器上测得 |
| 检索延迟中位数·hybrid ↓ | 56 ms |  |  | 实测 | real | 评测机器上测得 |
| 检索延迟中位数·keyword ↓ | 40 ms |  |  | 实测 | real | 评测机器上测得 |
| 真实记忆检索（人工 GT） ↑ | — |  |  | 缺失 | real | 人工标注尚未导入（qa-eval gt-sheet → gt-import）；当前只有临时 GT |

- 问答：85 道可回答、15 道无法回答；题目由 claude-code:opus 根据抽样证据写成，评分规则 qa-rubric-v1@02fc8811577c；结果生成于 2026-11-19T10:04:48Z，不是本次运行重新得到的
- 检索：**临时 GT（出题时的种子证据，未经人工确认），只用于诊断，不作结论**；参与评分 67 道

## 缺失的 Ground Truth

这些指标目前没有可信的标准答案，**没有计算**，也没有用合成或推测的数据代替：

- `memory.precision.human` 事实准确率（人工审计）：需要对本次写入逐条人工审计（明细 details/memory-report.md，口径见 eval/memory/audits/）；自动评分不能区分正确的额外信息与幻觉
- `memory.timeline.sourceDate` 写入条目的来源日期准确率：场景只标了事实锚点，没有标注每条事实应引用的日期
- `real.retrieval.humanGT` 真实记忆检索（人工 GT）：人工标注尚未导入（qa-eval gt-sheet → gt-import）；当前只有临时 GT
