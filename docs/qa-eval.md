# 真实记忆问答评测

用真实记忆的只读副本，测量助手问答管线（ADR-0011）的检索召回、答案正确率、无依据回答率和延迟。开发用，不随 App 发布。

代码：`Sources/AmaiQAEval`（逻辑，有单元测试）、`amai-memory qa-eval`（入口）、`AmaiInference/MLXTextChatModel`（纯文本 Judge 模型的加载）。

合成数据上的同一套问答与检索指标，以及感知、记忆生成与端到端评测，见统一 Quality Benchmark（`docs/benchmark.md`）；`amai-bench run --qa-workdir <工作目录>` 会把这里的汇总导入统一报告。

## 流程

```text
prepare   真实记忆 ──复制──▶ 工作目录/memory（只读副本）
generate  副本 → 证据目录 → 按种子抽样排出槽位 → 出题模型写成题目 → 本地校验，不合格带原因重试 → dataset.json
run       dataset → AssistantSession（MemoryRecall 混合检索 → 组装提示词 → 本地模型）→ answers.jsonl
judge     题目 + 标准答案 + 证据原文 + 助手当时看到的记忆 + 回答 → 独立 Judge → judgments.jsonl
report    summary.json（不含记忆正文）、records.jsonl、report.md（失败案例）
```

```sh
swift build -c release --product amai-memory        # mlx.metallib 已在 .build/release/ 时即可运行 run / judge
W=~/.amai-qa-eval/$(date +%Y%m%d-%H%M)
.build/release/amai-memory qa-eval prepare  --workdir $W
.build/release/amai-memory qa-eval generate --workdir $W            # Claude Code（opus），约 20 次调用
.build/release/amai-memory qa-eval run      --workdir $W            # App 配置的助手模型
.build/release/amai-memory qa-eval judge    --workdir $W            # 默认 Qwen2.5-7B-Instruct-4bit
.build/release/amai-memory qa-eval report   --workdir $W
```

`run` 与 `judge` 可以中断后重跑，已有结果的题跳过。`generate` 不覆盖已有的 `dataset.json`：题目一旦生成就固定，换题要换工作目录。副本是只读的，删除工作目录前先 `chmod -R u+w $W`。

## 隔离与隐私边界

- **真实记忆只被读取一次**（`prepare` 复制）。副本文件设为 0444、目录 0555，被测管线若尝试写入会直接报错；`run` 前后各校验一次副本摘要。
- 工作目录不能位于真实记忆目录、`~/Library/Application Support/Amai` 或仓库之内。
- 索引在工作目录里新建；不打开 App 的索引、会话记录（`assistant.sqlite`），不写配置。`run` 只**读取** `config.json` 里的助手模型、可读分区与记忆语言，使配置与日常一致；配置是云端模型时拒绝运行（除非用 `--answer-model` 指定本地模型）。
- **出题**：唯一离开本机的步骤。出题模型（Claude Code，`--tools ""`、不保存会话、空工作目录）每个槽位只收到抽样的 1–3 条证据，发送前经 `SecretRedactor` 脱敏。发出的条目数、字符数、脱敏次数记在 `dataset.json` 的 `egress` 与报告里。
- **作答与评分**完全在本机：被测模型是本地 MLX 模型，Judge 是另一个家族的本地模型。
- 终端输出与 `summary.json` 只有计数、比例与耗时；记忆正文只出现在工作目录里的 `dataset.json`、`answers.jsonl`、`judgments.jsonl`、`records.jsonl`、`report.md`。

## 题目

默认 100 道（`--count` 按比例缩放），种子固定时抽样可复现：

| 类型 | 数量 | 说明 |
|---|---|---|
| fact | 30 | 15 道长期记忆条目、15 道时间线片段；改写措辞 |
| temporal | 22 | relativeDate 8（只用代码算好的相对说法，如"上周五""6 天前"）、ordering 7（两件不同日子的事谁先、隔几天）、when 7（什么时候） |
| crossLingual | 15 | 英文 8、日文 7，问中文记忆 |
| followUp | 18 | 6 段对话 × 3 轮，同一天或同一项目；后两轮依赖上文指代，在同一个会话里依次提问 |
| unanswerable | 15 | absentEntity 9（记忆里没有的事）、noRecordDate 3（没有 daily 文件的日子）、falsePremise 3（与记忆矛盾的前提） |

本地校验（不合格的草稿带原因退回重写，最多 2 次，再换一组证据试一轮）：

- **不是原文匹配**：问题与证据原文（归一化后）的最长公共片段不超过 8 个字符，且不超过问题长度的一半；
- 问题语言与槽位一致；
- relativeDate 必须原样使用给定的相对说法、不出现绝对日期；noRecordDate 必须点明那一天；
- absentEntity 给出的关键词在整个副本中都不存在（falsePremise 给了也同样检查）。

评测中的"现在"固定为 `prepare` 的时刻：被测会话的时钟停在这一刻，"昨天""上周三"的解释与出题时一致。

## 指标

| 指标 | 定义 |
|---|---|
| 证据召回 | 可回答的题：所需证据的指纹（归一化原文的前 24 个字符）出现在提示词 `<memory>` 块中的比例；追问累计同一段对话前几轮给过的记忆。另报"全部召回"率 |
| 来源召回 | 来源列表中包含证据所在文件（daily 要求同一天）的比例。比证据召回宽松：同一天的时间线截断时可能来源对了、条目没进提示词 |
| 正确率 | Judge 判为 correct 的比例；另报 partial 与宽松得分（correct 1、partial 0.5）。无法回答的题，正确 = 明确说没有记录、不编造 |
| 无依据回答率 | 回答中有以事实口吻陈述、但既不被证据原文也不被助手当时看到的记忆支持的关于用户的说法（Judge 列出） |
| 延迟 | 提交到首字、到回答结束、提交后的准备（检索与组装）、其中检索、提交前的 `prepare`；另报提示词与命中缓存的 token |

诊断用：证据全部召回 / 未全部召回时各自的正确率（区分检索问题与作答问题）、可回答却说没有记录的比例、跨语言题是否用提问语言回答（按文字判断，不参与评分）。

失败类别：`retrieval-miss`（答错且证据没全进提示词）、`answer-error`（证据都在却答错）、`false-abstain`、`unanswerable-answered`、`ungrounded`、`pipeline-error`、`judge-error`（不计入依赖判定的指标）。

## 评分规则

`QARubric`（`qa-rubric-v1`）是固定文本，每条判定记录规则的版本与摘要，汇总时检查一致；单元测试钉住了摘要。改规则必须提升版本、更新测试，并在新的工作目录里重新评分，**不能为了某次评测的成绩修改**。Judge 温度 0，输出不是合格 JSON 时重试一次，仍失败记为 `judge-error`。

## 已知局限

- Judge 是 7B 模型，判定有噪声；"无依据"依赖它列出说法，可能漏报。需要时人工抽查 `report.md`。
- 题目由出题模型根据抽样证据写成，标准答案只依据这几条证据；如果记忆别处有更新或矛盾的信息，"标准答案"可能不是唯一正确的回答。
- 证据召回按指纹精确匹配：被截断（`[…]`）或只以日期区间摘要形式出现的条目算未召回，偏严格。
- 延迟在评测机器上测得；日常运行的 Amai 同时在做后台推理时会抬高延迟。评测不读屏幕，测不到屏幕 OCR 的耗时（见 `--assistant-check`）。

## 检索评测

只评测检索，不调用回答模型（`RetrievalEval.swift`、`RetrievalReport.swift`）。沿用上面生成的 100 道题与记忆副本。

```sh
.build/release/amai-memory qa-eval gt-sheet  --workdir $W     # 生成 retrieval/gt-annotate.html，在浏览器里人工标注
.build/release/amai-memory qa-eval gt-import --workdir $W --file ~/Downloads/gt-annotations.json [--annotator 名字]
.build/release/amai-memory qa-eval retrieval --workdir $W [--baseline $W/retrieval/runs-baseline.jsonl]
    # 有 gt.json 用人工 GT，否则用临时 GT 并在输出中注明；--baseline 在同一份 GT 上对比优化前后（comparison*.md）
```

被测对象（正式代码，评测不改动）：

| 系统 | 内容 |
|---|---|
| pipeline | 问答实际用的 `MemoryRecall`（默认 4K 预算），经 `AssistantSession` 调用，模型换成不回答的占位实现 `QASilentModel`；按对话依次提问。结果是 <memory> 块按行展开的有序列表，含同一段对话之前各轮给过的内容 |
| pipeline-8k | 同一条管线，8K 预算 |
| hybrid | `MemoryAPI.search` 取 50 条，与 `MemoryRecall` 的调用相同 |
| keyword | 同一接口不给向量模型（未下载向量模型时的退回路径） |

优化前（ADR-0011）保存的结果在 `retrieval/runs-baseline.jsonl`：那时正式调用取 6 条，hybrid / keyword 的前 6 名是取 6 条那次的结果，之后接取 50 条时的其余结果（候选池与 MMR 随条数变化，两者前 6 名只有约四分之一一致）。

**标准证据（GT）**：每道可回答的题由若干必需的信息点组成；一个信息点可以由几条记录中的任意一条提供（同一件事在长期记忆与当天时间线里都有）。只认人工标注：

- `gt-sheet` 默认只标注固定的 30 道代表题（`retrieval/gt-subset.json`，第一次生成后不再改动；`--all` 为全部 85 道）：按题型分层、按种子抽取，不看检索结果。覆盖多证据（ordering 4、追问 8）、跨语言 6、日期 9（relativeDate、when、ordering），追问只取第 2、3 轮。
- 每题合并候选池：出题时的种子证据、hybrid 前 10、keyword 前 5、pipeline 给出的全部内容及它整天取出的时间线，**优化前与当前两边的结果都并进来**，任何一边找到的记录都能被标注。候选按文件与时间排序，不标出来源，也不标出哪条是种子；另可在全部记忆里搜索补充。页面上的参考答案是出题模型写的，注明"不是标注依据"。
- 题目有歧义、记忆不足以回答时由标注者排除，排除数按原因报告。
- 临时 GT（`--gt provisional`）：出题时代码抽样的种子证据，每条一个信息点、没有替代记录；追问题的种子证据是整段对话共用的，不计入。只用于标注完成之前粗看，结论以人工 GT 为准。

**指标**：R@K（信息点召回，K = 1/3/6/10/20）、Full@K（所需信息点全部召回）、P@K（前 K 项中相关项的比例，分母为 K）、nDCG@K（二值增益：一项让某个信息点首次满足记 1）、全部返回项上的同类指标。**固定 token 预算**（4096 / 8192）：按顺序装入，直到下一项会超出预算，只算这个前缀里的召回，返回再多也不会虚增；token 按 `MemoryChunker` 的估算（汉字每字 1，其余每 4 字符 1）。延迟：pipeline 是会话里记忆检索那一步，hybrid / keyword 是正式条数的一次调用。

**无法回答的题**：各系统返回内容的比例、项数与 token；hybrid / keyword 第一名得分的分布，以及它区分可回答与无法回答（absentEntity、noRecordDate）的 AUROC——能否靠一个分数门槛拒绝。falsePremise 的相关记忆对反驳前提有用，单列不计入误检。

**瓶颈归因**：pipeline 漏掉的每个信息点按顺序取第一个成立的原因：日期写法没被认出（问题里有那天的说法，却没整天取出）→ 那天的时间线没放全（优化前是 1800 字符截断，之后是预算装不下）→ 整个块超过 5000 字符（仅优化前）→ 被日期范围筛掉 → hybrid 的名次在 pipeline 放进去的检索结果条数之后（优化前固定 6 条）→ 名次在条数之内却没给出 → hybrid 前 50 名都没有（另计纯关键词能否找到）。

局限：候选池之外的相关记录只能靠标注者搜索补充，漏标会让召回偏高；absentEntity 题的关键词在出题时按字面校验过不在记忆里，对关键词得分天然不利，AUROC 可能偏乐观。
