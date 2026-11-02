# 架构决策记录（ADR）

每个重要技术 / 架构决策一个文件，编号递增，文件名 `NNNN-<slug>.md`。

状态：`Proposed`（提案，待用户确认）→ `Accepted` / `Rejected` → `Superseded by NNNN`。

模板：

```markdown
# NNNN · 标题

- 状态：Proposed | Accepted | Rejected | Superseded by NNNN
- 日期：YYYY-MM-DD

## 背景
## 决策
## 备选方案
## 取舍与风险
## 影响
```

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-markdown-memory.md) | 以 Markdown 文件作为长期记忆的主要存储 | Accepted |
| [0002](0002-tech-stack.md) | macOS MVP 技术栈 | Accepted |
| [0003](0003-memory-consolidation.md) | 记忆整理（M4）：日终摘要、work 专题与 summary | Accepted（文件布局由 0006 取代） |
| [0004](0004-cloud-model-provider.md) | 记忆整理可切换到云端 API 大模型（Anthropic / OpenAI） | Accepted |
| [0005](0005-subscription-accounts.md) | 用 ChatGPT / Claude 订阅额度做记忆整理 | Accepted |
| [0006](0006-memory-schema-v1.md) | Memory Schema v1：单文件分区、依据类型与无损迁移 | Accepted（部分取代 0003 的文件布局） |
